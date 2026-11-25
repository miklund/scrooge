-- Scrooge probe build.
-- Targets the Classic client (Interface 16001). Some fallbacks for the old 1.12 API
-- remain from before the client version was known and are harmless.

local MAX_LOG = 2000
local nlog = 0
local ui = {}
local scan = { active = false }
local lastAuctions = {}
local lastCount = 0
local registered = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function money(c)
  if type(c) ~= "number" then return tostring(c) end
  local g = math.floor(c / 10000)
  local s = math.floor((c - g * 10000) / 100)
  local cp = c - g * 10000 - s * 100
  return g .. "g " .. s .. "s " .. cp .. "c"
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

local function ahOpen()
  return AuctionFrame and AuctionFrame:IsVisible()
end

local function has(v)
  if v then return "yes" end
  return "NO"
end

-- Item id from an item link.
local function itemIdFromLink(link)
  if not link then return nil end
  local _, _, id = string.find(link, "item:(%d+)")
  return id
end

-- GetItemInfo moved to C_Item on modern clients; the sell price is the 11th return.
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

-- Returns a table with named fields; detects which return layout the client uses.
local function readAuction(i)
  local r = { GetAuctionItemInfo("list", i) }
  local a = {}
  a.name = r[1]
  a.count = r[3]
  if type(r[7]) == "string" then
    -- 1.13+ layout: levelColHeader at 7
    a.minBid, a.minInc, a.buyout, a.bid, a.highBidder = r[8], r[9], r[10], r[11], r[12]
    a.owner = r[14]
    a.itemId = r[17]
  else
    -- 1.12 layout
    a.minBid, a.minInc, a.buyout, a.bid, a.highBidder = r[7], r[8], r[9], r[10], r[11]
    a.owner = r[12]
  end
  a.link = GetAuctionItemLink and GetAuctionItemLink("list", i)
  if GetAuctionItemTimeLeft then a.timeLeft = GetAuctionItemTimeLeft("list", i) end
  a.vendor = vendorPrice(a.link)
  return a
end

----------------------------------------------------------------------
-- Probes
----------------------------------------------------------------------

local function probeEnvironment()
  log("=== Environment ===")
  if GetBuildInfo then
    local v, b, d, toc = GetBuildInfo()
    log("Build: " .. tostring(v) .. " (" .. tostring(b) .. ", " .. tostring(d) .. ") toc=" .. tostring(toc))
  end
  log("Lua version: " .. tostring(_VERSION))
  log("QueryAuctionItems: " .. has(QueryAuctionItems))
  log("CanSendAuctionQuery: " .. has(CanSendAuctionQuery))
  log("GetNumAuctionItems: " .. has(GetNumAuctionItems))
  log("GetItemInfo (global): " .. has(GetItemInfo))
  log("GetAuctionItemInfo: " .. has(GetAuctionItemInfo))
  log("GetAuctionItemLink: " .. has(GetAuctionItemLink))
  log("GetAuctionItemTimeLeft: " .. has(GetAuctionItemTimeLeft))
  log("PlaceAuctionBid: " .. has(PlaceAuctionBid))
  log("C_AuctionHouse (retail API): " .. has(C_AuctionHouse))
  log("C_Timer: " .. has(C_Timer))
  if C_AuctionHouse then
    local names = { "SendBrowseQuery", "SendSearchQuery", "ReplicateItems", "GetNumReplicateItems",
      "GetReplicateItemInfo", "GetReplicateItemLink", "GetReplicateItemTimeLeft", "GetNumItemSearchResults",
      "GetItemSearchResultInfo", "GetBrowseResults", "PlaceBid", "GetBidInfo", "IsThrottledMessageSystemReady",
      "MakeItemKey", "GetItemKeyFromItem", "GetItemCommodityStatus" }
    for _, n in ipairs(names) do log("  C_AuctionHouse." .. n .. ": " .. has(C_AuctionHouse[n])) end
  end
  if C_Item then log("C_Item.GetItemInfo: " .. has(C_Item.GetItemInfo)) end
  for name, ok in pairs(registered) do log("Event " .. name .. ": " .. (ok and "registered" or "UNKNOWN")) end
  log("AuctionFrame visible: " .. has(ahOpen()))
  if CanSendAuctionQuery then
    local can, canAll = CanSendAuctionQuery()
    log("CanSendAuctionQuery() -> " .. tostring(can) .. ", " .. tostring(canAll))
  end
  if NUM_AUCTION_ITEMS_PER_PAGE then
    log("NUM_AUCTION_ITEMS_PER_PAGE: " .. tostring(NUM_AUCTION_ITEMS_PER_PAGE))
  end

  -- Linen Cloth (id 2589) vendors for 13 copper; shows whether GetItemInfo returns a price.
  log("--- GetItemInfo(2589) (Linen Cloth, expect sellPrice 13) ---")
  local t = itemInfo("item:2589:0:0:0")
  if not t then log("No GetItemInfo / C_Item.GetItemInfo available"); return end
  for i = 1, 12 do log("  [" .. i .. "] " .. tostring(t[i])) end
  log("sellPrice at [11]: " .. tostring(t[11]))
end

local function sendQuery(page, getAll)
  if not QueryAuctionItems then log("QueryAuctionItems missing"); return false end
  local ok, err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, page, 0, 0, getAll and true or nil)
  if not ok then log("QueryAuctionItems error: " .. tostring(err)); return false end
  return true
end

local function dumpAuctions(limit)
  local n, total = GetNumAuctionItems("list")
  log("=== Dump: batch=" .. tostring(n) .. " total=" .. tostring(total) .. " ===")
  if not n or n == 0 then log("No auction data. Run a scan first."); return end
  if limit > n then limit = n end

  -- Raw return values of the first auction so the real layout is visible.
  local r = { GetAuctionItemInfo("list", 1) }
  log("Raw GetAuctionItemInfo(list,1):")
  for i = 1, 18 do log("  [" .. i .. "] " .. tostring(r[i])) end

  for i = 1, limit do
    local a = readAuction(i)
    local line = i .. ": " .. tostring(a.name) .. " x" .. tostring(a.count) ..
      " minBid=" .. tostring(a.minBid) .. " buyout=" .. tostring(a.buyout) ..
      " bid=" .. tostring(a.bid) .. " owner=" .. tostring(a.owner) ..
      " left=" .. tostring(a.timeLeft) .. " vendor=" .. tostring(a.vendor)
    if a.vendor and a.minBid then
      line = line .. " profit=" .. tostring(a.vendor * (a.count or 1) - a.minBid)
    end
    log(line)
  end
end

local function probeTooltip()
  log("=== Tooltip probe (auction 1) ===")
  local n = GetNumAuctionItems("list")
  if not n or n == 0 then log("No auction data. Run a scan first."); return end
  GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  GameTooltip:SetAuctionItem("list", 1)
  for i = 1, GameTooltip:NumLines() do
    local left = getglobal("GameTooltipTextLeft" .. i)
    local right = getglobal("GameTooltipTextRight" .. i)
    log("  L" .. i .. ": " .. tostring(left and left:GetText()) .. " | " .. tostring(right and right:GetText()))
  end
  log("GameTooltip.hasMoney: " .. tostring(GameTooltip.hasMoney))
  GameTooltip:Hide()
end

----------------------------------------------------------------------
-- Scanning
----------------------------------------------------------------------

local function summarizeScan(reason)
  local withVendor, profitable, bestProfit = 0, 0, nil
  for i = 1, lastCount do
    local a = lastAuctions[i]
    if a.vendor and a.vendor > 0 then
      withVendor = withVendor + 1
      if a.minBid and a.count then
        local p = a.vendor * a.count - a.minBid
        if p > 0 then profitable = profitable + 1 end
        if not bestProfit or p > bestProfit then bestProfit = p end
      end
    end
  end
  log("=== Scan " .. reason .. " ===")
  log("Pages: " .. scan.pages .. ", auctions read: " .. lastCount .. ", reported total: " .. tostring(scan.total))
  log("Time: " .. string.format("%.1f", GetTime() - scan.start) .. "s")
  log("Auctions with vendor price: " .. withVendor .. ", with minBid < vendor: " .. profitable)
  if bestProfit then log("Best profit by minBid: " .. money(bestProfit)) end
  scan.active = false
end

local function readPage()
  local n, total = GetNumAuctionItems("list")
  n = n or 0
  scan.total = total
  for i = 1, n do
    lastCount = lastCount + 1
    lastAuctions[lastCount] = readAuction(i)
  end
  scan.pages = scan.pages + 1
  log("Page " .. (scan.page + 1) .. ": " .. n .. " auctions (total " .. tostring(total) .. ")")
  return n, total
end

local function advanceScan()
  local n, total = readPage()
  local perPage = NUM_AUCTION_ITEMS_PER_PAGE or 50
  if scan.getAll or scan.single or n == 0 or (scan.page + 1) * perPage >= (total or 0) then
    summarizeScan("finished")
    return
  end
  scan.page = scan.page + 1
  scan.pending = true
  scan.waitStart = GetTime()
end

local function startScan(opts)
  if scan.active then log("Scan already running"); return end
  if not ahOpen() then log("Open the auction house first"); return end
  lastAuctions = {}
  lastCount = 0
  scan = { active = true, page = 0, pages = 0, total = 0, start = GetTime(),
    single = opts.single, getAll = opts.getAll, pending = true, waitStart = GetTime() }
  log("=== Scan started (" .. (opts.getAll and "getAll" or opts.single and "single page" or "all pages") .. ") ===")
end

local function onUpdate()
  if not scan.active or not scan.pending then return end
  if GetTime() - scan.waitStart > 30 then
    log("Timed out waiting for the auction house")
    summarizeScan("aborted (timeout)")
    return
  end
  local can, canAll = true, true
  if CanSendAuctionQuery then can, canAll = CanSendAuctionQuery() end
  if scan.getAll and not canAll then return end
  if not can then return end
  scan.pending = false
  scan.awaiting = true
  if scan.getAll then log("Sending getAll query (client may freeze briefly)...") end
  if not sendQuery(scan.page, scan.getAll) then
    scan.awaiting = false
    summarizeScan("aborted (query error)")
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
  local f
  -- 1.13+ needs the BackdropTemplate mixin; 1.12 has no such template and errors.
  local ok, frame = pcall(CreateFrame, "Frame", "ScroogeFrame", UIParent, "BackdropTemplate")
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
  makeButton("Scan 1 page", 150, -40, function() startScan({ single = true }) end)
  makeButton("Full scan", 280, -40, function() startScan({}) end)
  makeButton("GetAll scan", 410, -40, function() startScan({ getAll = true }) end)
  makeButton("Dump 10 auctions", 20, -70, function() dumpAuctions(10) end)
  makeButton("Tooltip probe", 150, -70, probeTooltip)
  makeButton("Cancel scan", 280, -70, function()
    if scan.active then summarizeScan("cancelled") else log("No scan running") end
  end)
  makeButton("Clear log", 410, -70, function() ui.out:Clear() end)

  local out = CreateFrame("ScrollingMessageFrame", "ScroogeOutput", f)
  out:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -105)
  out:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
  out:SetFontObject(GameFontHighlightSmall)
  out:SetJustifyH("LEFT")
  out:SetFading(false)
  if out.SetMaxLines then out:SetMaxLines(500) end
  out:EnableMouseWheel(true)
  out:SetScript("OnMouseWheel", function(self, delta)
    local d = delta or arg1
    local w = self or this
    if d > 0 then w:ScrollUp() else w:ScrollDown() end
  end)
  ui.out = out
  f:Hide()
end

----------------------------------------------------------------------
-- Events and slash command
----------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")

-- Events that may or may not exist on this client; unknown ones are skipped, not fatal.
local probeEvents = {
  "AUCTION_ITEM_LIST_UPDATE", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "REPLICATE_ITEM_LIST_UPDATE", "ITEM_SEARCH_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "AUCTION_MULTISELL_UPDATE", "GET_ITEM_INFO_RECEIVED",
}
local function registerProbeEvents()
  for _, name in ipairs(probeEvents) do
    local ok = pcall(ev.RegisterEvent, ev, name)
    registered[name] = ok
    log("Event " .. name .. ": " .. (ok and "registered" or "UNKNOWN"))
  end
end

local noisy = { GET_ITEM_INFO_RECEIVED = true }

ev:SetScript("OnEvent", function(self, e, a1)
  if e == "ADDON_LOADED" then
    if not a1 or string.lower(a1) ~= "scrooge" then return end
    if type(ScroogeLog) ~= "table" then ScroogeLog = {} end
    nlog = 0
    while ScroogeLog[nlog + 1] do nlog = nlog + 1 end
    buildUI()
    registerProbeEvents()
    log("Scrooge loaded. Type /scrooge to open the probe window.")
    print("Scrooge 0.0.4 loaded. Type /scrooge.")
    return
  end
  if not noisy[e] then log("Event fired: " .. e) end
  if e == "AUCTION_ITEM_LIST_UPDATE" and scan.active and scan.awaiting then
    scan.awaiting = false
    advanceScan()
  end
end)
ev:SetScript("OnUpdate", onUpdate)

SLASH_SCROOGE1 = "/scrooge"
SlashCmdList["SCROOGE"] = function()
  if not ui.frame then print("Scrooge: UI not built yet"); return end
  if ui.frame:IsVisible() then ui.frame:Hide() else ui.frame:Show() end
end
