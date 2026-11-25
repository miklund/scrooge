-- Scrooge probe build.
-- The client (Interface 16001) uses the modern C_AuctionHouse API, not the legacy
-- QueryAuctionItems/GetAuctionItemInfo. Scanning uses C_AuctionHouse.ReplicateItems().

local MAX_LOG = 2000
local nlog = 0
local ui = {}
local scan = { active = false }
local auctions = {}
local ahShown = false
local registered = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function money(c)
  if type(c) ~= "number" then return tostring(c) end
  local sign = ""
  if c < 0 then sign = "-"; c = -c end
  local g = math.floor(c / 10000)
  local s = math.floor((c - g * 10000) / 100)
  local cp = c - g * 10000 - s * 100
  return sign .. g .. "g " .. s .. "s " .. cp .. "c"
end

local function log(msg)
  msg = tostring(msg)
  if ui.out then ui.out:AddMessage(msg) end
  if type(ScroogeLog) == "table" then
    if nlog >= MAX_LOG then ScroogeLog = {}; nlog = 0 end
    nlog = nlog + 1
    ScroogeLog[nlog] = date("%H:%M:%S") .. " " .. msg
  end
end

local function has(v)
  if v then return "yes" end
  return "NO"
end

local function ahOpen()
  if ahShown then return true end
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown()) or false
end

-- GetItemInfo lives in C_Item on this client; sell price is the 11th return.
local function itemInfo(link)
  if C_Item and C_Item.GetItemInfo then return { C_Item.GetItemInfo(link) } end
  if GetItemInfo then return { GetItemInfo(link) } end
  return nil
end

local function vendorPrice(link)
  if not link then return nil end
  local t = itemInfo(link)
  return t and t[11]
end

local function nextBid(a)
  if a.bid and a.bid > 0 then return a.bid + (a.minInc or 0) end
  return a.minBid
end

----------------------------------------------------------------------
-- Probes
----------------------------------------------------------------------

local function probeEnvironment()
  log("=== Environment ===")
  local v, b, d, toc = GetBuildInfo()
  log("Build: " .. tostring(v) .. " (" .. tostring(b) .. ", " .. tostring(d) .. ") toc=" .. tostring(toc))
  log("Legacy QueryAuctionItems: " .. has(QueryAuctionItems))
  log("Legacy GetAuctionItemInfo: " .. has(GetAuctionItemInfo))
  log("C_AuctionHouse: " .. has(C_AuctionHouse))
  if C_AuctionHouse then
    local names = { "SendBrowseQuery", "GetBrowseResults", "ReplicateItems", "GetNumReplicateItems",
      "GetReplicateItemInfo", "GetReplicateItemLink", "GetReplicateItemTimeLeft", "SendSearchQuery",
      "GetNumItemSearchResults", "GetItemSearchResultInfo", "PlaceBid", "GetBidInfo",
      "IsThrottledMessageSystemReady", "GetItemCommodityStatus" }
    for _, n in ipairs(names) do log("  C_AuctionHouse." .. n .. ": " .. has(C_AuctionHouse[n])) end
    if C_AuctionHouse.GetNumReplicateItems then
      log("GetNumReplicateItems() now: " .. tostring(C_AuctionHouse.GetNumReplicateItems()))
    end
    if C_AuctionHouse.IsThrottledMessageSystemReady then
      log("IsThrottledMessageSystemReady(): " .. tostring(C_AuctionHouse.IsThrottledMessageSystemReady()))
    end
  end
  log("C_Item.GetItemInfo: " .. has(C_Item and C_Item.GetItemInfo))
  log("AH open (by event flag or frame): " .. has(ahOpen()))
  for name, ok in pairs(registered) do log("Event " .. name .. ": " .. (ok and "registered" or "UNKNOWN")) end
  log("Linen Cloth vendor price (expect 13): " .. tostring(vendorPrice("item:2589:0:0:0")))
end

local function frameCheck()
  log("=== Frame check ===")
  log("ahShown flag (AUCTION_HOUSE_SHOW/CLOSED): " .. tostring(ahShown))
  log("AuctionHouseFrame: " .. has(AuctionHouseFrame) .. ", shown: " .. tostring(AuctionHouseFrame and AuctionHouseFrame:IsShown()))
  log("AuctionFrame: " .. has(AuctionFrame) .. ", shown: " .. tostring(AuctionFrame and AuctionFrame:IsShown()))
end

local function browseOnePage()
  if not ahOpen() then log("Open the auction house first"); return end
  scan = { active = true, kind = "browse", start = GetTime(), waitStart = GetTime() }
  log("Sending SendBrowseQuery (empty search)...")
  C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
end

local function onBrowseResults()
  local res = C_AuctionHouse.GetBrowseResults()
  log("Browse results: " .. tostring(res and table.getn(res)))
  if res then
    for i = 1, math.min(5, table.getn(res)) do
      local r = res[i]
      local id = r.itemKey and r.itemKey.itemID
      log("  " .. i .. ": itemID=" .. tostring(id) .. " minPrice=" .. tostring(r.minPrice) ..
        " qty=" .. tostring(r.totalQuantity) .. " vendor=" .. tostring(vendorPrice(id and ("item:" .. id))))
    end
  end
  scan.active = false
end

----------------------------------------------------------------------
-- Replicate scan (all auctions at once)
----------------------------------------------------------------------

local function readReplicate(i)
  local r = { C_AuctionHouse.GetReplicateItemInfo(i) }
  local a = { name = r[1], count = r[3], minBid = r[8], minInc = r[9], buyout = r[10],
    bid = r[11], highBidder = r[12], owner = r[14], itemId = r[17] }
  a.link = C_AuctionHouse.GetReplicateItemLink and C_AuctionHouse.GetReplicateItemLink(i)
  if C_AuctionHouse.GetReplicateItemTimeLeft then a.timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(i) end
  return a
end

local function rank(topN)
  local rows, unknown = {}, 0
  for i = 1, table.getn(auctions) do
    local a = auctions[i]
    local link = a.link or (a.itemId and ("item:" .. a.itemId))
    local vendor = vendorPrice(link)
    local cost = nextBid(a)
    if vendor and cost and a.count then
      local profit = vendor * a.count - cost
      rows[table.getn(rows) + 1] = { a = a, profit = profit, vendor = vendor, cost = cost }
    else
      unknown = unknown + 1
      if a.itemId and C_Item and C_Item.RequestLoadItemDataByID and unknown <= 500 then
        C_Item.RequestLoadItemDataByID(a.itemId)
      end
    end
  end
  table.sort(rows, function(x, y) return x.profit > y.profit end)
  local positive = 0
  for i = 1, table.getn(rows) do if rows[i].profit > 0 then positive = positive + 1 end end
  log("=== Ranking: " .. table.getn(rows) .. " priced, " .. unknown .. " without vendor price (uncached), " ..
    positive .. " with next bid < vendor value ===")
  for i = 1, math.min(topN, table.getn(rows)) do
    local r = rows[i]
    log(i .. ". " .. tostring(r.a.name) .. " x" .. tostring(r.a.count) .. " bid " .. money(r.cost) ..
      " vendor " .. money(r.vendor * r.a.count) .. " PROFIT " .. money(r.profit) ..
      " left=" .. tostring(r.a.timeLeft) .. " buyout=" .. money(r.a.buyout))
  end
  if unknown > 0 then log("Press 'Rank results' again in a few seconds to price items that were not cached.") end
end

local function finishReplicate()
  local n = C_AuctionHouse.GetNumReplicateItems() or 0
  auctions = {}
  for i = 0, n - 1 do
    local ok, a = pcall(readReplicate, i)
    if ok and a and a.name then auctions[table.getn(auctions) + 1] = a end
  end
  -- Index base may be 1 on some clients; fall back if 0-based read nothing.
  if table.getn(auctions) == 0 and n > 0 then
    for i = 1, n do
      local ok, a = pcall(readReplicate, i)
      if ok and a and a.name then auctions[table.getn(auctions) + 1] = a end
    end
  end
  log("=== Replicate scan finished ===")
  log("Reported items: " .. n .. ", read: " .. table.getn(auctions) .. ", time: " ..
    string.format("%.1f", GetTime() - scan.start) .. "s")
  scan.active = false
  rank(10)
end

local function startReplicate()
  if scan.active then log("Scan already running"); return end
  if not ahOpen() then log("Open the auction house first"); return end
  scan = { active = true, kind = "replicate", start = GetTime(), waitStart = GetTime(), lastEvent = nil }
  log("Calling ReplicateItems (client may freeze briefly; the server may limit how often this works)...")
  C_AuctionHouse.ReplicateItems()
end

local function onUpdate()
  if not scan.active then return end
  if scan.kind == "replicate" and scan.lastEvent and GetTime() - scan.lastEvent > 2 then
    scan.lastEvent = nil
    local ok, err = pcall(finishReplicate)
    if not ok then log("ERROR: " .. tostring(err)); scan.active = false end
  elseif GetTime() - scan.waitStart > 90 then
    log("Timed out waiting for the auction house")
    scan.active = false
  end
end

local function dumpAuctions(limit)
  local n = table.getn(auctions)
  log("=== Dump: " .. n .. " stored auctions ===")
  if n == 0 then log("No data. Run 'Replicate scan' first."); return end
  local r = { C_AuctionHouse.GetReplicateItemInfo(0) }
  log("Raw GetReplicateItemInfo(0):")
  for i = 1, 19 do log("  [" .. i .. "] " .. tostring(r[i])) end
  for i = 1, math.min(limit, n) do
    local a = auctions[i]
    local v = vendorPrice(a.link or (a.itemId and ("item:" .. a.itemId)))
    log(i .. ": " .. tostring(a.name) .. " x" .. tostring(a.count) .. " minBid=" .. tostring(a.minBid) ..
      " bid=" .. tostring(a.bid) .. " buyout=" .. tostring(a.buyout) .. " owner=" .. tostring(a.owner) ..
      " left=" .. tostring(a.timeLeft) .. " vendor=" .. tostring(v))
  end
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

local function makeButton(label, x, y, onClick)
  local b = CreateFrame("Button", nil, ui.frame, "UIPanelButtonTemplate")
  b:SetWidth(125)
  b:SetHeight(24)
  b:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", x, y)
  b:SetText(label)
  b:SetScript("OnClick", function()
    local ok, err = pcall(onClick)
    if not ok then log("ERROR: " .. tostring(err)) end
  end)
  return b
end

local function buildUI()
  local ok, frame = pcall(CreateFrame, "Frame", "ScroogeFrame", UIParent, "BackdropTemplate")
  local f
  if ok then f = frame else f = CreateFrame("Frame", "ScroogeFrame", UIParent) end
  ui.frame = f
  f:SetWidth(580)
  f:SetHeight(440)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() ScroogeFrame:StartMoving() end)
  f:SetScript("OnDragStop", function() ScroogeFrame:StopMovingOrSizing() end)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", f, "TOP", 0, -16)
  title:SetText("Scrooge - API probe")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  makeButton("Environment", 20, -40, probeEnvironment)
  makeButton("Replicate scan", 150, -40, startReplicate)
  makeButton("Browse 1 page", 280, -40, browseOnePage)
  makeButton("Rank results", 410, -40, function() rank(10) end)
  makeButton("Dump 10 auctions", 20, -70, function() dumpAuctions(10) end)
  makeButton("Frame check", 150, -70, frameCheck)
  makeButton("Cancel scan", 280, -70, function()
    if scan.active then scan.active = false; log("Scan cancelled") else log("No scan running") end
  end)
  makeButton("Clear log", 410, -70, function() ui.out:Clear() end)

  local out = CreateFrame("ScrollingMessageFrame", "ScroogeOutput", f)
  out:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -105)
  out:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
  out:SetFontObject(GameFontHighlightSmall)
  out:SetJustifyH("LEFT")
  out:SetFading(false)
  out:SetMaxLines(500)
  out:EnableMouseWheel(true)
  out:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
  end)
  ui.out = out
  f:Hide()
end

----------------------------------------------------------------------
-- Events and slash command
----------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")

local probeEvents = {
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}

local noisy = { REPLICATE_ITEM_LIST_UPDATE = true }

ev:SetScript("OnEvent", function(self, e, a1)
  if e == "ADDON_LOADED" then
    if not a1 or string.lower(a1) ~= "scrooge" then return end
    if type(ScroogeLog) ~= "table" then ScroogeLog = {} end
    nlog = 0
    while ScroogeLog[nlog + 1] do nlog = nlog + 1 end
    buildUI()
    for _, name in ipairs(probeEvents) do
      registered[name] = pcall(ev.RegisterEvent, ev, name)
    end
    print("Scrooge 0.0.5 loaded. Type /scrooge.")
    return
  end
  if e == "AUCTION_HOUSE_SHOW" then ahShown = true
  elseif e == "AUCTION_HOUSE_CLOSED" then ahShown = false end
  if not noisy[e] then log("Event fired: " .. e) end
  if e == "REPLICATE_ITEM_LIST_UPDATE" and scan.active and scan.kind == "replicate" then
    scan.lastEvent = GetTime()
    log("Replicate update, items now: " .. tostring(C_AuctionHouse.GetNumReplicateItems()))
  elseif e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and scan.active and scan.kind == "browse" then
    local ok, err = pcall(onBrowseResults)
    if not ok then log("ERROR: " .. tostring(err)); scan.active = false end
  end
end)
ev:SetScript("OnUpdate", onUpdate)

SLASH_SCROOGE1 = "/scrooge"
SlashCmdList["SCROOGE"] = function()
  if not ui.frame then print("Scrooge: UI not built yet"); return end
  if ui.frame:IsShown() then ui.frame:Hide() else ui.frame:Show() end
end
