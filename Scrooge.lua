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
      local profit = (vendor - cost) * a.count
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
-- Deal scanner: browse all item groups, then search each non-commodity item for
-- individual auctions. Commodities have no bids, so only their lowest unit price
-- (from the browse result) is compared with the vendor price.
----------------------------------------------------------------------

local MAX_ROWS = 300
local MAX_MORE_BROWSE = 40
local SEARCH_TIMEOUT = 6
-- Retail rule of thumb: the next bid must be at least 5% above the current bid.
local BID_INCREMENT = 0.05
local deals = { bid = {}, buyout = {} }
local ds = { active = false }
local vendorCache = {}
local refreshAll

local function maxSearches()
  return (ScroogeDB and ScroogeDB.maxSearches) or 1000
end

local function vendorById(id)
  local p = vendorCache[id]
  if p ~= nil then return p end
  p = vendorPrice("item:" .. id)
  if p then
    vendorCache[id] = p
  elseif C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(id)
  end
  return p
end

local function throttleReady()
  local f = C_AuctionHouse.IsThrottledMessageSystemReady
  if f then return f() end
  return true
end

local function setStatus(msg)
  ds.status = msg
  if ui.status then ui.status:SetText(msg) end
end

local timeLeftText = { [0] = "<30m", [1] = "<2h", [2] = "<12h", [3] = "<48h" }
local function fmtTimeLeft(r)
  local s = r.timeLeftSeconds
  if s then
    if s >= 3600 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 60) .. "m"
  end
  return timeLeftText[r.timeLeft] or "?"
end

local function addDeal(kind, row)
  local list = deals[kind]
  list[#list + 1] = row
  ui.dirty = true
end

local function sortDeals()
  local byProfit = function(a, b) return a.profit > b.profit end
  table.sort(deals.bid, byProfit)
  table.sort(deals.buyout, byProfit)
end

local function finishDealScan(msg)
  ds.active = false
  ds.paused = false
  if ui.pauseBtn then ui.pauseBtn:SetText("Pause") end
  setStatus(msg)
  log("=== Deal scan: " .. msg .. " ===")
  ui.dirty = true
end

local function isCommodity(key)
  if not C_AuctionHouse.GetItemCommodityStatus then return false end
  local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, key)
  return ok and status == 2
end

local function startDealScan()
  if ds.active then return end
  if not ahOpen() then setStatus("Open the auction house first"); return end
  deals = { bid = {}, buyout = {} }
  ds = { active = true, phase = "browse", start = GetTime(), waitStart = GetTime(), moreRequests = 0,
    searched = 0, timeouts = 0, skipped = 0 }
  ui.dirty = true
  setStatus("Starting...")
  log("=== Deal scan started (max item searches: " .. maxSearches() .. ") ===")
end

local function beginItemData()
  ds.results = C_AuctionHouse.GetBrowseResults() or {}
  ds.phase = "itemdata"
  ds.waitStart = GetTime()
  ds.nextCheck = 0
  log("Browse finished: " .. #ds.results .. " item groups")
end

local function buildQueue()
  local queue = {}
  for i = 1, #ds.results do
    local r = ds.results[i]
    local key = r.itemKey
    local id = key and key.itemID
    local vendor = id and id > 0 and vendorCache[id]
    if vendor and vendor > 0 then
      if isCommodity(key) then
        local unit = r.minPrice
        if unit and unit > 0 and unit < vendor then
          addDeal("buyout", { itemId = id, qty = 1, qtyText = "each (" .. tostring(r.totalQuantity) .. ")",
            price = unit, vendorEach = vendor, profit = vendor - unit, timeLeft = "-", commodity = true })
        end
      else
        queue[#queue + 1] = { key = key, id = id, vendor = vendor, ratio = (r.minPrice or 0) / vendor }
      end
    else
      ds.skipped = ds.skipped + 1
    end
  end
  -- Lowest price relative to vendor value first, so the likeliest deals are searched before the cap.
  table.sort(queue, function(a, b)
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.vendor > b.vendor
  end)
  local total = #queue
  while #queue > maxSearches() do queue[#queue] = nil end
  ds.queue = queue
  ds.qi = 0
  ds.phase = "search"
  log("Item groups: " .. #ds.results .. ", to search: " .. #queue .. " of " .. total ..
    ", skipped (no vendor price/uncached): " .. ds.skipped)
end

local function sendSearch(key)
  local sorts = {}
  if Enum and Enum.AuctionHouseSortOrder then
    sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  end
  C_AuctionHouse.SendSearchQuery(key, sorts, true)
end

local function processItemResults()
  local entry = ds.cur.entry
  local key = entry.key
  local n = C_AuctionHouse.GetNumItemSearchResults(key) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
    if r and not r.containsOwnerItem then
      local qty = r.quantity or 1
      -- minBid, bidAmount and buyoutAmount are per item on this client, even for stacks.
      local vendor = entry.vendor
      local minBid, bidAmt, buyout = r.minBid or 0, r.bidAmount or 0, r.buyoutAmount or 0
      local cost = minBid
      if bidAmt > 0 then cost = bidAmt + math.max(1, math.floor(bidAmt * BID_INCREMENT)) end
      local left = fmtTimeLeft(r)
      if qty > 1 and not ds.loggedStack then
        ds.loggedStack = true
        log("Stack sample: item " .. entry.id .. " qty=" .. qty .. " minBid=" .. minBid .. " bidAmount=" ..
          bidAmt .. " buyout=" .. buyout .. " vendor each=" .. vendor)
      end
      if cost > 0 and cost < vendor and (buyout == 0 or cost < buyout) then
        addDeal("bid", { itemId = entry.id, link = r.itemLink, qty = qty, price = cost,
          vendorEach = vendor, profit = (vendor - cost) * qty, timeLeft = left, auctionId = r.auctionID })
      end
      if buyout > 0 and buyout < vendor then
        addDeal("buyout", { itemId = entry.id, link = r.itemLink, qty = qty, price = buyout,
          vendorEach = vendor, profit = (vendor - buyout) * qty, timeLeft = left, auctionId = r.auctionID })
      end
    end
  end
  ds.cur = nil
  ds.searched = ds.searched + 1
end

local function onItemResults(key)
  local cur = ds.cur
  if not cur or not key or key.itemID ~= cur.entry.id then return end
  local k = cur.entry.key
  local full = C_AuctionHouse.HasFullItemSearchResults and C_AuctionHouse.HasFullItemSearchResults(k)
  if not full and cur.more < 3 and C_AuctionHouse.RequestMoreItemSearchResults then
    cur.more = cur.more + 1
    cur.sentAt = GetTime()
    C_AuctionHouse.RequestMoreItemSearchResults(k)
    return
  end
  processItemResults()
end

local function onCommodityResults(id)
  local cur = ds.cur
  if not cur or id ~= cur.entry.id then return end
  local info = C_AuctionHouse.GetCommoditySearchResultInfo(id, 1)
  if info and info.unitPrice and info.unitPrice < cur.entry.vendor then
    addDeal("buyout", { itemId = id, qty = 1, qtyText = "each", price = info.unitPrice,
      vendorEach = cur.entry.vendor, profit = cur.entry.vendor - info.unitPrice, timeLeft = "-" })
  end
  ds.cur = nil
  ds.searched = ds.searched + 1
end

local function dsOnEvent(e, a1)
  if e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or e == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    if ds.phase == "browse" then
      ds.lastEvent = GetTime()
      ds.waitStart = GetTime()
      ds.gotAny = true
    end
  elseif e == "ITEM_SEARCH_RESULTS_UPDATED" then
    onItemResults(a1)
  elseif e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    onCommodityResults(a1)
  end
end

local function dsTick()
  local now = GetTime()
  if ds.phase == "browse" then
    if not ds.sent then
      if not throttleReady() then return end
      ds.sent = true
      ds.waitStart = now
      setStatus("Browsing auction house...")
      C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
    elseif ds.lastEvent and now - ds.lastEvent > 1 then
      local full = C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.HasFullBrowseResults()
      if full or ds.moreRequests >= MAX_MORE_BROWSE then
        beginItemData()
      elseif throttleReady() then
        ds.moreRequests = ds.moreRequests + 1
        ds.lastEvent = nil
        ds.waitStart = now
        setStatus("Loading more results (" .. ds.moreRequests .. ")...")
        C_AuctionHouse.RequestMoreBrowseResults()
      end
    elseif now - ds.waitStart > 20 then
      if ds.gotAny then beginItemData() else finishDealScan("Browse timed out") end
    end
  elseif ds.phase == "itemdata" then
    if now < ds.nextCheck then return end
    ds.nextCheck = now + 0.5
    local unknown = 0
    for i = 1, #ds.results do
      local key = ds.results[i].itemKey
      local id = key and key.itemID
      if id and id > 0 and vendorById(id) == nil then unknown = unknown + 1 end
    end
    if unknown == 0 or now - ds.waitStart > 8 then
      buildQueue()
    else
      setStatus("Loading item data (" .. unknown .. " left)...")
    end
  elseif ds.phase == "search" then
    if ds.paused and not ds.cur then return end
    if ds.cur then
      if now - ds.cur.sentAt > SEARCH_TIMEOUT then
        if ds.cur.more > 0 then
          processItemResults()
        else
          ds.timeouts = ds.timeouts + 1
          ds.cur = nil
        end
      end
      return
    end
    local nxt = ds.queue[ds.qi + 1]
    if not nxt then
      finishDealScan("Done in " .. string.format("%.0f", now - ds.start) .. "s: " .. #deals.bid ..
        " bid deals, " .. #deals.buyout .. " buyout deals (searched " .. ds.searched ..
        ", timeouts " .. ds.timeouts .. ", skipped " .. ds.skipped .. ")")
      return
    end
    if not throttleReady() then return end
    ds.qi = ds.qi + 1
    ds.cur = { entry = nxt, sentAt = now, more = 0 }
    local t = itemInfo("item:" .. nxt.id)
    setStatus("Searching " .. ds.qi .. "/" .. #ds.queue .. ": " .. tostring(t and t[1] or nxt.id) ..
      " (" .. #deals.bid .. " bid, " .. #deals.buyout .. " buyout deals)")
    sendSearch(nxt.key)
  end
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

local function makeButton(label, x, y, onClick, parent, width)
  parent = parent or ui.debugPanel
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(width or 125)
  b:SetHeight(24)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  b:SetText(label)
  b:SetScript("OnClick", function()
    local ok, err = pcall(onClick)
    if not ok then log("ERROR: " .. tostring(err)) end
  end)
  return b
end

local function buildDebugPanel()
  local f = ui.debugPanel

  makeButton("Environment", 0, 0, probeEnvironment)
  makeButton("Replicate scan", 130, 0, startReplicate)
  makeButton("Browse 1 page", 260, 0, browseOnePage)
  makeButton("Rank results", 390, 0, function() rank(10) end)
  makeButton("Dump 10 auctions", 0, -30, function() dumpAuctions(10) end)
  makeButton("Frame check", 130, -30, frameCheck)
  makeButton("Cancel scan", 260, -30, function()
    if scan.active then scan.active = false; log("Scan cancelled") else log("No scan running") end
  end)
  makeButton("Clear log", 390, -30, function() ui.out:Clear() end)

  local out = CreateFrame("ScrollingMessageFrame", "ScroogeOutput", f)
  out:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -65)
  out:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  out:SetFontObject(GameFontHighlightSmall)
  out:SetJustifyH("LEFT")
  out:SetFading(false)
  out:SetMaxLines(500)
  out:EnableMouseWheel(true)
  out:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
  end)
  ui.out = out
end

local ROW_H = 18
local COLS = {
  { key = "name", w = 200, label = "Item" },
  { key = "qty", w = 80, label = "Qty" },
  { key = "price", w = 100, label = "Price each" },
  { key = "vendor", w = 100, label = "Vendor each" },
  { key = "profit", w = 100, label = "Total profit" },
  { key = "left", w = 50, label = "Left" },
}

local function coin(c)
  if GetCoinTextureString then return GetCoinTextureString(c) end
  return money(c)
end

local function rowName(row)
  if row.link then return row.link end
  local t = itemInfo("item:" .. row.itemId)
  if t and t[2] then return t[2] end
  return "item:" .. row.itemId
end

local function plainName(d)
  return (rowName(d):match("%[(.-)%]")) or rowName(d)
end

local function removeDeal(kind, d)
  local list = deals[kind]
  for i = 1, #list do
    if list[i] == d then table.remove(list, i); break end
  end
  ui.dirty = true
end

local function searchInAH(d)
  if not ahOpen() then print("Scrooge: open the auction house first"); return end
  local name = plainName(d)
  local f = AuctionHouseFrame
  local ok = f and f.SearchBar and f.SearchBar.SearchBox and pcall(function()
    if f.SetDisplayMode and AuctionHouseFrameDisplayMode then f:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
    f.SearchBar.SearchBox:SetText(name)
    f.SearchBar:StartSearch()
  end)
  if ok then print("Scrooge: searching for " .. name) else print("Scrooge: could not drive the auction house search for " .. name) end
end

local pending

StaticPopupDialogs["SCROOGE_CONFIRM"] = {
  text = "%s",
  button1 = "Yes",
  button2 = "Cancel",
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  OnAccept = function() if pending then local f = pending; pending = nil; f() end end,
  OnCancel = function()
    pending = nil
    if C_AuctionHouse.CancelCommoditiesPurchase and ds.commodity then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
    ds.commodity = nil
  end,
}

local function confirm(text, fn)
  pending = fn
  StaticPopup_Show("SCROOGE_CONFIRM", text)
end

local function buyDeal(kind, d)
  if not ahOpen() then print("Scrooge: open the auction house first"); return end
  local name = rowName(d)
  if d.commodity then
    if ds.active and not ds.paused then print("Scrooge: pause the scan first"); return end
    ds.commodity = { kind = kind, d = d }
    C_AuctionHouse.StartCommoditiesPurchase(d.itemId, 1)
    return
  end
  if not d.auctionId then print("Scrooge: no auction id for this row"); return end
  local what, amount
  if kind == "buyout" then
    what, amount = "Buy out", d.price
  else
    what, amount = "Bid on", d.minBidNext or d.price
  end
  confirm(what .. " " .. name .. " x" .. d.qty .. " for " .. coin(amount) .. "?\nVendor value each: " .. coin(d.vendorEach), function()
    C_AuctionHouse.PlaceBid(d.auctionId, amount)
    removeDeal(kind, d)
    print("Scrooge: " .. what:lower() .. " sent for " .. name .. " at " .. coin(amount))
  end)
end

local function onCommodityPrice(unitPrice, totalPrice)
  local c = ds.commodity
  if not c then return end
  local d = c.d
  if unitPrice >= d.vendorEach then
    print("Scrooge: price is now " .. coin(unitPrice) .. ", no longer below vendor price. Cancelled.")
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    ds.commodity = nil
    return
  end
  confirm("Buy 1 x " .. rowName(d) .. " for " .. coin(totalPrice) .. "?\nVendor value: " .. coin(d.vendorEach), function()
    C_AuctionHouse.ConfirmCommoditiesPurchase(d.itemId, 1)
  end)
end

local function onCommodityDone(ok)
  local c = ds.commodity
  if not c then return end
  ds.commodity = nil
  if ok then print("Scrooge: bought 1 x " .. rowName(c.d)) else print("Scrooge: purchase failed") end
end

local function createList(parent, kind, emptyText)
  local list = { kind = kind, rows = {} }
  local x = 0
  for _, c in ipairs(COLS) do
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x + 2, 0)
    fs:SetWidth(c.w)
    fs:SetJustifyH("LEFT")
    fs:SetText(c.label)
    x = x + c.w
  end
  local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -20)
  sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -26, 28)
  local function mkBtn(text, x, w, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x, 2)
    b:SetText(text)
    b:SetScript("OnClick", function()
      local d = list.selected
      if not d then print("Scrooge: select a row first"); return end
      fn(d)
    end)
    return b
  end
  mkBtn(kind == "buyout" and "Buyout" or "Bid", 0, 90, function(d) buyDeal(kind, d) end)
  mkBtn("Find in AH", 95, 90, searchInAH)
  mkBtn("Done", 190, 70, function(d) list.selected = nil; removeDeal(kind, d) end)
  local hint = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 270, 8)
  hint:SetText("Click a row to select, shift-click to find it in the AH")
  local content = CreateFrame("Frame", nil, sf)
  content:SetWidth(630)
  content:SetHeight(1)
  sf:SetScrollChild(content)
  list.content = content
  list.empty = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  list.empty:SetPoint("CENTER", parent, "CENTER", 0, 0)
  list.empty:SetText(emptyText)
  return list
end

local function getRow(list, i)
  local row = list.rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, list.content)
  row:SetWidth(630)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", list.content, "TOPLEFT", 0, -(i - 1) * ROW_H)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  row.cols = {}
  local x = 0
  for _, c in ipairs(COLS) do
    local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", row, "LEFT", x + 2, 0)
    fs:SetWidth(c.w - 4)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    row.cols[c.key] = fs
    x = x + c.w
  end
  row:SetScript("OnEnter", function(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetHyperlink, GameTooltip, d.link or ("item:" .. d.itemId))
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    if not self.data then return end
    list.selected = self.data
    if IsShiftKeyDown() then searchInAH(self.data) end
    ui.dirty = true
  end)
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints()
  row.sel:SetColorTexture(0.2, 0.5, 1, 0.3)
  list.rows[i] = row
  return row
end

local function refreshList(list)
  local data = deals[list.kind]
  local n = math.min(#data, MAX_ROWS)
  for i = 1, n do
    local d = data[i]
    local row = getRow(list, i)
    row.data = d
    row.cols.name:SetText(rowName(d))
    row.cols.qty:SetText(d.qtyText or ("x" .. d.qty))
    row.cols.price:SetText(coin(d.price))
    row.cols.vendor:SetText(coin(d.vendorEach))
    row.cols.profit:SetText(coin(d.profit))
    row.cols.left:SetText(d.timeLeft or "")
    if list.selected == d then row.sel:Show() else row.sel:Hide() end
    row:Show()
  end
  for i = n + 1, #list.rows do list.rows[i]:Hide() end
  list.content:SetHeight(math.max(1, n * ROW_H))
  if n == 0 then list.empty:Show() else list.empty:Hide() end
end

refreshAll = function()
  sortDeals()
  refreshList(ui.bidList)
  refreshList(ui.buyoutList)
  ui.tabs[1]:SetText("Bid deals (" .. #deals.bid .. ")")
  ui.tabs[2]:SetText("Buyout deals (" .. #deals.buyout .. ")")
end

local function selectTab(n)
  for i = 1, 3 do
    if i == n then
      ui.panels[i]:Show()
      ui.tabs[i]:Disable()
    else
      ui.panels[i]:Hide()
      ui.tabs[i]:Enable()
    end
  end
end

local function buildUI()
  local ok, frame = pcall(CreateFrame, "Frame", "ScroogeFrame", UIParent, "BackdropTemplate")
  local f
  if ok then f = frame else f = CreateFrame("Frame", "ScroogeFrame", UIParent) end
  ui.frame = f
  f:SetWidth(700)
  f:SetHeight(520)
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
  title:SetText("Scrooge")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  makeButton("Scan AH", 20, -38, startDealScan, f, 100)
  local pauseBtn
  pauseBtn = makeButton("Pause", 125, -38, function()
    if not ds.active then return end
    ds.paused = not ds.paused
    pauseBtn:SetText(ds.paused and "Resume" or "Pause")
    if ds.paused then setStatus("Paused. Buy what you want, then press Resume.") end
  end, f, 70)
  makeButton("Stop", 200, -38, function()
    if ds.active then finishDealScan("Stopped") end
  end, f, 60)
  ui.pauseBtn = pauseBtn
  ui.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.status:SetPoint("TOPLEFT", f, "TOPLEFT", 270, -44)
  ui.status:SetWidth(400)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetText("Open the auction house and press Scan AH.")

  ui.tabs, ui.panels = {}, {}
  local labels = { "Bid deals (0)", "Buyout deals (0)", "Debug" }
  for i = 1, 3 do
    ui.tabs[i] = makeButton(labels[i], 20 + (i - 1) * 150, -70, function() selectTab(i) end, f, 145)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -102)
    p:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    ui.panels[i] = p
  end
  ui.selectTab = selectTab
  ui.bidList = createList(ui.panels[1], "bid", "No bid deals yet. Items whose next bid is below the vendor price appear here.")
  ui.buyoutList = createList(ui.panels[2], "buyout", "No buyout deals yet. Items whose buyout is below the vendor price appear here.")
  ui.debugPanel = ui.panels[3]
  buildDebugPanel()
  selectTab(1)
  f:Hide()
end

----------------------------------------------------------------------
-- Events and slash command
----------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")

local probeEvents = {
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "GET_ITEM_INFO_RECEIVED",
  "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_SHOW_ERROR",
}

local noisy = {
  REPLICATE_ITEM_LIST_UPDATE = true, GET_ITEM_INFO_RECEIVED = true,
  AUCTION_HOUSE_BROWSE_RESULTS_ADDED = true, ITEM_SEARCH_RESULTS_UPDATED = true,
  COMMODITY_SEARCH_RESULTS_UPDATED = true, AUCTION_HOUSE_THROTTLED_SYSTEM_READY = true,
}

ev:SetScript("OnEvent", function(self, e, a1, a2)
  if e == "ADDON_LOADED" then
    if not a1 or string.lower(a1) ~= "scrooge" then return end
    if type(ScroogeLog) ~= "table" then ScroogeLog = {} end
    if type(ScroogeDB) ~= "table" then ScroogeDB = {} end
    nlog = 0
    while ScroogeLog[nlog + 1] do nlog = nlog + 1 end
    buildUI()
    for _, name in ipairs(probeEvents) do
      registered[name] = pcall(ev.RegisterEvent, ev, name)
    end
    print("Scrooge 0.2.1 loaded. Type /scrooge.")
    return
  end
  if e == "AUCTION_HOUSE_SHOW" then ahShown = true
  elseif e == "AUCTION_HOUSE_CLOSED" then
    ahShown = false
    if ds.active then finishDealScan("Auction house closed") end
  end
  if e == "GET_ITEM_INFO_RECEIVED" then ui.dirty = true end
  if e == "COMMODITY_PRICE_UPDATED" then onCommodityPrice(a1, a2 or 0)
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then onCommodityDone(true)
  elseif e == "COMMODITY_PURCHASE_FAILED" then onCommodityDone(false)
  elseif e == "AUCTION_HOUSE_SHOW_ERROR" then print("Scrooge: auction house error " .. tostring(a1)) end
  if not noisy[e] and not ds.active then log("Event fired: " .. e) end
  if ds.active then
    local ok, err = pcall(dsOnEvent, e, a1)
    if not ok then log("ERROR: " .. tostring(err)) end
  end
  if e == "REPLICATE_ITEM_LIST_UPDATE" and scan.active and scan.kind == "replicate" then
    scan.lastEvent = GetTime()
    log("Replicate update, items now: " .. tostring(C_AuctionHouse.GetNumReplicateItems()))
  elseif e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" and scan.active and scan.kind == "browse" then
    local ok, err = pcall(onBrowseResults)
    if not ok then log("ERROR: " .. tostring(err)); scan.active = false end
  end
end)

ev:SetScript("OnUpdate", function()
  onUpdate()
  if ds.active then
    local ok, err = pcall(dsTick)
    if not ok then
      log("ERROR: " .. tostring(err))
      finishDealScan("Error: " .. tostring(err))
    end
  end
  if ui.dirty and ui.frame and ui.frame:IsShown() and GetTime() >= (ui.nextRefresh or 0) then
    ui.dirty = false
    ui.nextRefresh = GetTime() + 0.7
    local ok, err = pcall(refreshAll)
    if not ok then log("ERROR refreshing list: " .. tostring(err)) end
  end
end)

SLASH_SCROOGE1 = "/scrooge"
SlashCmdList["SCROOGE"] = function(msg)
  if not ui.frame then print("Scrooge: UI not built yet"); return end
  msg = string.lower(msg or "")
  local _, _, n = string.find(msg, "^max%s+(%d+)")
  if n then
    ScroogeDB.maxSearches = tonumber(n)
    print("Scrooge: will search at most " .. n .. " items per scan")
    return
  end
  if msg == "debug" then
    ui.frame:Show()
    ui.selectTab(3)
    return
  end
  if ui.frame:IsShown() then ui.frame:Hide() else ui.frame:Show(); ui.dirty = true end
end
