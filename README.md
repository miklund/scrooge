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

- WoW Classic client, Interface `16001` (`_classic_` folder), as used on WoW Forever.
- Access to the auction house (the addon can only scan while the AH window is open).
- Addon is written in Lua with the standard WoW addon API; no external dependencies are required.

### Functional requirements

- Scan the auction house (full or paged scan, respecting the server's query throttle).
- Resolve the vendor sell price per item.
- Rank auctions by absolute profit and by percentage profit.
- Display the ranked list in a window next to the AH frame.
- Filters: minimum profit, maximum bid (budget), auction time left, exclude own auctions and auctions where you are already the high bidder.

### Non-functional / caveats

- Prices are in copper.
- Only auctions that expire (12h/24h/48h) without being outbid pay out, so the list is a ranking of opportunities, not a guaranteed profit. Competing bidders may outbid you; that is fine because you are only out the money if you stop bidding.
- Your bid money is locked until you are outbid or the auction ends.
- Auctions with a short time left are the most practical to bid on, since the wait is short.

## Feasibility (initial research)

These answers come from knowledge of the Classic AH API and Auctionator, not from running code yet. Items marked *verify* need confirming in-game on WoW Forever.

### 1. Is this possible?

Yes. The required data is available to addons:

- `QueryAuctionItems(...)` triggers a scan; `CanSendAuctionQuery()` tells whether a query may be sent (queries are throttled). Results arrive via the `AUCTION_ITEM_LIST_UPDATE` event.
- `GetNumAuctionItems("list")` and `GetAuctionItemInfo("list", index)` return item name, count, `minBid`, `minIncrement`, `buyoutPrice`, `bidAmount` (current bid), `highBidder`, `owner`, and `itemId`. `GetAuctionItemLink` gives the link and `GetAuctionItemTimeLeft` the remaining time.
- `GetItemInfo(itemId)` returns the vendor sell price (`sellPrice`). The default UI tooltips show the same value. It may return `nil` until the item is cached, so lookups must be retried on `GET_ITEM_INFO_RECEIVED`.
- `PlaceAuctionBid("list", index, amount)` can place the bid. This is protected only in the sense that it needs a hardware event, which is fine for a click.

Details to *verify* on WoW Forever: whether the "getAll" scan (`QueryAuctionItems` with `getAll = true`) is allowed and how often, and the exact `GetAuctionItemInfo` return order for this client build.

### 2. Can we use Auctionator's database?

Not for this purpose. Auctionator stores aggregated prices per item (the lowest **buyout** price seen, in its SavedVariables), not the per-auction **bid** values we need. Its saved data is also only written to disk on logout or `/reload`, although other addons can read its in-memory globals while the game runs. It also only has the latest snapshot per item, with no per-auction bid, count, or time left.

Conclusion: Scrooge has to do its own scan.

### 3. Can we reuse Auctionator's scanning code?

Probably yes, with caveats:

- Auctionator is open source, so its scan logic (query throttling, paging, handling of `AUCTION_ITEM_LIST_UPDATE`) can be used as a reference or reused. **Check its license on the CurseForge/GitHub page before copying code** and keep attribution if required.
- The scanning loop itself is short (query a page, wait for the event, read results, next page), so writing our own is small and avoids a dependency on Auctionator's internals, which change between versions.
- Alternatively, Scrooge could depend on Auctionator as a library, but this only makes sense if Auctionator exposes per-auction data, which it does not appear to.

Reference: <https://www.curseforge.com/wow/addons/auctionator>

## Planned structure

```
(repo root = addon folder)
  Scrooge.toc      -- addon manifest
  Scanner.lua      -- AH scan with throttling and paging
  Vendor.lua       -- vendor price lookup and caching
  Ranking.lua      -- profit calculation and sorting
  UI.lua           -- results window anchored to the AH frame
```

## Roadmap

1. Skeleton addon (`.toc`, slash command `/scrooge`).
2. Scanner that dumps all auctions to a table.
3. Vendor price lookup and profit calculation, printed to chat.
4. Results window with sorting and filters.
5. One-click bid on a selected row.

## Installation

Copy this repository's contents into a folder named `Scrooge` at `World of Warcraft/_classic_/Interface/AddOns/Scrooge/` and restart or `/reload`. The client is Interface `16001` (same as the HealerStats addon).

## Probe build (current state)

The current addon is a probe for finding out what the WoW Forever client supports. Type `/scrooge` to open the window and use it with the auction house open:

| Button | What it tests |
| --- | --- |
| Environment | Client build, which AH APIs exist, and whether `GetItemInfo` returns a vendor price (tested on Linen Cloth, expected 13c) |
| Scan 1 page | A single `QueryAuctionItems` and how the results look |
| Full scan | Paged scan with throttling; reports pages, auctions, time, and how many auctions have `minBid` below vendor price |
| GetAll scan | Whether the one-shot "get all" query is allowed (can freeze the client briefly) |
| Dump 10 auctions | Raw `GetAuctionItemInfo` return values plus parsed fields and vendor price |
| Tooltip probe | Lines of the AH tooltip, to see if the vendor price shows up there |

Output is shown in the window and also saved to `WTF/Account/<ACCOUNT>/SavedVariables/Scrooge.lua` (written on logout or `/reload`). Send back that file or copy the window text.
