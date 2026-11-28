# Scrooge

Proof of concept for a World of Warcraft (Classic-era client, played on WoW Forever) addon that finds **auction house bid-flipping opportunities**: auctions whose current minimum bid is lower than what a vendor pays for the item.

## Idea

Many sellers post items with default auction settings. The default starting bid and buyout are often below the vendor sell price. Buying such items by buyout and vendoring them gives a small, tedious profit (e.g. 100 chain mail leggings for ~2 silver total).

Instead of buying out, **bid the minimum on auctions and wait for them to expire**. If nobody outbids you, you pay only the starting bid, which is often well below the buyout. That gives a larger margin per item, and the bid can be placed without paying full price up front.

The hard part is finding the auctions with the best margin. Scrooge does that:

1. Scan the auction house.
2. For each auction, look up the item's vendor sell price.
3. Compute `profit = vendorPrice * count - currentBid` (where the current bid is the minimum bid, or the current highest bid plus the minimum increment).
4. Show a list sorted by profit (and by profit margin), so you can bid on the best ones.

## Requirements

- WoW Classic client, Interface `16001` (`_classic_` folder), as used on WoW Forever. It uses the modern `C_AuctionHouse` API.
- Access to the auction house (the addon can only scan while the AH window is open).
- Addon is written in Lua with the standard WoW addon API; no external dependencies are required.

### Functional requirements

- Scan the auction house (browse query for candidates, then per-item search for individual auctions, respecting the server's query throttle).
- Resolve the vendor sell price per item.
- Rank auctions by absolute profit and by percentage profit.
- Display the ranked list in a window next to the AH frame.
- Filters: minimum profit, maximum bid (budget), auction time left, exclude own auctions and auctions where you are already the high bidder.

### Non-functional / caveats

- Prices are in copper.
- Only auctions that expire (12h/24h/48h) without being outbid pay out, so the list is a ranking of opportunities, not a guaranteed profit. Competing bidders may outbid you; that is fine because you are only out the money if you stop bidding.
- Your bid money is locked until you are outbid or the auction ends.
- Auctions with a short time left are the most practical to bid on, since the wait is short.

## What we learned (probe results from the WoW Forever client)

The probe addon was run in the game client (Interface `16001`) at the Stormwind auction house. Initial assumptions were based on the legacy Classic API; the probe showed that is wrong for this client.

### The client uses the modern `C_AuctionHouse` API

- The legacy scan API (`QueryAuctionItems`, `GetAuctionItemInfo`, `GetNumAuctionItems`) is **not available**, and the legacy event `AUCTION_ITEM_LIST_UPDATE` is **unknown** (registering it raises an error).
- The AH window is `AuctionHouseFrame`. `AuctionFrame` does not exist, so "is the AH open" must be checked with `AuctionHouseFrame:IsShown()` or by tracking `AUCTION_HOUSE_SHOW` / `AUCTION_HOUSE_CLOSED` (the event flag worked).
- All of these exist: `C_AuctionHouse.SendBrowseQuery`, `GetBrowseResults`, `ReplicateItems`, `GetNumReplicateItems`, `GetReplicateItemInfo`, `GetReplicateItemLink`, `GetReplicateItemTimeLeft`, `SendSearchQuery`, `GetNumItemSearchResults`, `GetItemSearchResultInfo`, `PlaceBid`, `GetBidInfo`, `IsThrottledMessageSystemReady`, `GetItemCommodityStatus`.
- Events that exist: `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED`, `REPLICATE_ITEM_LIST_UPDATE`, `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED`, `ITEM_SEARCH_RESULTS_UPDATED`, `COMMODITY_SEARCH_RESULTS_UPDATED`, `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `AUCTION_MULTISELL_UPDATE`.
- Addon load details: the `ADDON_LOADED` argument is the **folder name** and may differ in case from the addon name (here `scrooge`), so compare case-insensitively. `BackdropTemplate` is needed for `SetBackdrop`.

### Vendor price works

- `GetItemInfo` is not a global; use `C_Item.GetItemInfo(link or "item:<id>")`. The sell price is the **11th** return value (Linen Cloth returns 13 copper as expected).
- It returns `nil` for items that are not cached. After the browse query the first results gave `vendor=nil`. We must request item data (`C_Item.RequestLoadItemDataByID`) and re-rank after `GET_ITEM_INFO_RECEIVED`. The **Rank results** button does this by hand.

### Browse queries work but only give per-item data

- `SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })` returned **500** results via `AUCTION_HOUSE_BROWSE_RESULTS_UPDATED`. Each result has `itemKey.itemID`, `minPrice` and `totalQuantity`.
- That is the cheapest price per item, **not individual auctions with their bids**, so it cannot be used for the bid strategy on its own. It is still useful as a cheap first filter (items whose `minPrice` is below the vendor price).
- The browse list in the default UI is the retail-style layout: items are grouped, with a price and an "Available" count. Fish, cloth and other stackable goods appear to be **commodities**, which are sold by unit price without bids. The bid strategy likely only works for non-commodity items (equipment such as the chain mail leggings), which use `GetItemSearchResultInfo` / `SendSearchQuery` with an item key.
- `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` fires after a query, so queries are throttled and the next one should wait for it (or `IsThrottledMessageSystemReady()`).

### Replicate scan: not yet working

- `C_AuctionHouse.GetNumReplicateItems()` returned 0 before any scan.
- Calling `ReplicateItems()` did **not** produce a `REPLICATE_ITEM_LIST_UPDATE` event, and the scan produced no data (0 auctions stored, ranking empty). So this "get all" path is either disabled on WoW Forever, throttled, or needs more waiting or a different trigger. This is still open (see below).

### Answers to the original questions

1. **Is this possible?** Partly confirmed. We can read the AH, get vendor prices and place bids (`PlaceBid` exists). What is not yet confirmed is getting **per-auction bid data** for all items efficiently. Candidate routes: browse query to find candidate items, then `SendSearchQuery` per item key to get individual auctions.
2. **Can we use Auctionator's database?** No. It keeps aggregated per-item prices (lowest buyout), not per-auction bids, and only writes its saved data on logout or `/reload`. We have to do our own scan. (The Auctionator tab is installed in the AH window on this client, so it can coexist.)
3. **Can we reuse Auctionator's scanning code?** Possibly as a reference for the modern API (browse then item search, throttling, handling uncached items). It is open source; **check its license before copying code**. Because the client uses `C_AuctionHouse`, old Classic scanning code (such as the older Auctionator scan) would not work as is.

### Open questions / next steps

- Why does `ReplicateItems()` give no event? Try waiting longer, check `IsThrottledMessageSystemReady()` first, and watch whether the default UI itself triggers it.
- Per-item search: call `SendSearchQuery(itemKey, sorts, true)` for a non-commodity item, and dump `GetItemSearchResultInfo` to see if `minBid`, `bidAmount`, `buyoutAmount`, `timeLeft` and `owner` are present.
- Check `GetItemCommodityStatus(itemKey)` to know which items are commodities (no bids) and skip them.
- Cache item data so vendor prices are known before ranking, and rank on `GET_ITEM_INFO_RECEIVED`.
- Measure the throttle: how many items per second can we search without being blocked.
- Confirm in the default UI that item auctions here really expose a bid (not only buyout).

Reference: <https://www.curseforge.com/wow/addons/auctionator>

## Structure

```
(repo root = addon folder)
  Scrooge.toc      -- addon manifest
  Scrooge.lua      -- deal scanner, main window and debug tab (single file for now)
```

## Roadmap

1. ~~Skeleton addon (`.toc`, slash command `/scrooge`).~~
2. ~~Probe the client's AH API (debug tab).~~
3. ~~Deal scanner and results window (bid deals and buyout deals).~~ Untested in-game.
4. Verify the scanner against the real server (throttle, per-item search data, commodity detection) and tune.
5. Filters (minimum profit, budget, time left) and one-click bid on a selected row.

## Usage

`/scrooge` opens the main window. Open the auction house, press **Scan AH**, and wait. Two tabs show the results, sorted by profit (vendor value minus price):

- **Bid deals:** non-commodity auctions where the next bid (the minimum bid, or the current bid plus 5%) is below the vendor value, and below the buyout. Shows the time left, since you have to wait for the auction to end.
- **Buyout deals:** auctions where the buyout is below the vendor value. Commodities (stackable goods sold by unit price) have no bids, so they only show up here, using the lowest unit price.
- **Debug:** the API probe buttons (see below). `/scrooge debug` opens this tab directly.

How a scan works:

1. A browse query for all items, then more results are requested until the list is complete.
2. Vendor prices are looked up for every item. Items without a known vendor price (not cached, or unsellable) are skipped.
3. Commodities are compared directly from the browse result's lowest unit price.
4. Every other item is searched for its individual auctions (throttled, one at a time), lowest price relative to vendor price first (the likeliest deals). By default at most 1000 items are searched per scan; change this with `/scrooge max <number>`.

Prices: on this client `minBid`, `bidAmount` and `buyoutAmount` are **per item**, even for stacks (a stack of 6 shows the same price as a single item). The lists show price and vendor value per item, and profit is the per-item margin times the stack size. The bid assumption is not yet confirmed; the first stacked auction of a scan is written to the Debug log as `Stack sample`.

Caveats: The 5% minimum bid increment is the retail rule and is an assumption. Your own auctions are ignored.

## Installation

Copy this repository's contents into a folder named `Scrooge` at `World of Warcraft/_classic_/Interface/AddOns/Scrooge/` and restart or `/reload`. The client is Interface `16001` (same as the HealerStats addon).

## Debug tab (API probe)

The debug tab is the probe used for finding out what the WoW Forever client supports. Use it with the auction house open:

| Button | What it tests |
| --- | --- |
| Environment | Client build, which `C_AuctionHouse` functions and events exist, and the vendor price lookup (Linen Cloth, expected 13c) |
| Replicate scan | `C_AuctionHouse.ReplicateItems()`, the "get all" scan; reads every auction with bid data and prints the top 10 by profit (vendor value minus next bid) |
| Browse 1 page | `SendBrowseQuery`; shows per-item results (min price and quantity only, no per-auction bids) |
| Rank results | Re-ranks the last scan, useful after item data has been cached |
| Dump 10 auctions | Raw `GetReplicateItemInfo` return values plus parsed fields and vendor price |
| Frame check | Whether the AH frame and `AUCTION_HOUSE_SHOW` event are detected |

The client uses the modern `C_AuctionHouse` API (not `QueryAuctionItems`/`GetAuctionItemInfo`), and `GetItemInfo` is `C_Item.GetItemInfo`.

Output is shown in the window and also saved to `WTF/Account/<ACCOUNT>/SavedVariables/Scrooge.lua` (written on logout or `/reload`). Send back that file or copy the window text.

## Buying from Scrooge

Click a row to select it, then use the buttons under the list:

- **Bid / Buyout** places the bid (next minimum bid) or buys out that exact auction immediately (no confirmation), removes the row and selects the next one. Commodity rows (no single auction) buy 1 unit via the commodity purchase flow and are cancelled if the price is no longer below vendor.
- **Find in AH** (or shift-click the row) fills the auction house search box with the item name and searches.
- **Done** removes the row without buying.

Bids and buyouts use `C_AuctionHouse.PlaceBid(auctionID, amount)`; auction IDs come from the last scan, so a row may fail if the auction changed. Errors are printed to chat. Untested in-game as of 0.2.0.

**Pause / Resume** halts the scan after the current item search so you can buy or bid; Resume continues where it left off. Single-auction bids and buyouts also work while scanning; commodity purchases require a pause.

Closing the auction house during the item-search phase pauses the scan; reopen it and press Resume to continue. Closing it earlier (browse phase) ends the scan.
