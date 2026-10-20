# AH History

A World of Warcraft: Forever addon that records auction house prices over time and tells you whether the current price is a good deal.

## Features

- **Full auction house scan** with one click: the **Scan prices** button at the bottom of the auction house window (placed next to **CraftProfit Scan** if you use that addon), or `/ahh scan`.
- **Daily price history** per item: lowest price per unit, median price and quantity listed.
- **Tooltip info** on any item (bags, bank, auction house, chat links):

  ```
  AH History
  Lowest now            12g 50s
  7-day typical low     14g 10s
  30-day typical low    15g 20s
  All-time low           9g 80s
  Good price (-18%)
  ```

- **Price verdict** comparing the current lowest price to the 30-day typical low:

  | Verdict | Meaning |
  |---|---|
  | All-time low! | Cheapest it has ever been in your data |
  | Great price | 15% or more below typical |
  | Good price | 5–15% below typical |
  | Normal price | Between 5% below and 10% above typical |
  | Expensive | 10% or more above typical |

  The verdict appears once an item has at least 3 days of history. Until then the tooltip shows "Building history (x/3 days)".

- **Separate data per realm and faction.**
- **Automatic cleanup:** history older than 180 days is removed on login.

## Installation

1. Copy the `AHHistory` folder into `World of Warcraft\<your Forever folder>\Interface\AddOns\`.
2. Check the interface number in-game:

   ```
   /dump (select(4, GetBuildInfo()))
   ```

   If it is not `16001`, change the `## Interface:` line in `AHHistory.toc` to that number. Otherwise, tick "Load out of date AddOns" on the AddOns screen.
3. Log in, open the auction house and click **Scan prices**.

## Commands

| Command | What it does |
|---|---|
| `/ahh scan` | Full scan (auction house must be open) |
| `/ahh auto` | Toggle automatic scan when you open the auction house |
| `/ahh stats` | Number of items tracked and time of the last scan |
| `/ahh [item link]` | Print the last 14 days for an item (shift-click the item into chat) |

## Good to know

- **History only grows when you scan.** Addons can't access the internet, so scan regularly (for example once per play session) for useful verdicts.
- **Full scans have a cooldown** of about 15 minutes, set by the server.
- **Data is saved on logout or `/reload`.** A game crash loses the current session's scans.
- **Large auction houses** can freeze the game for a few seconds during a scan, which is why automatic scanning is off by default.
- Prices are **buyout per unit**. Bid-only auctions are ignored.

## Troubleshooting

- **Tooltip shows "AH History" with a red error line:** report the error text.
- **"No auction data yet":** the item wasn't listed during your scans.
- **Nothing appears at all:** make sure **AH History** is enabled on the AddOns screen at character select.
- To see Lua errors while testing: `/console scriptErrors 1`

## Files

- `AHHistory.toc`: addon metadata
- `AHHistory.lua`: all addon code
- Saved data: `WTF\Account\<account>\SavedVariables\AHHistory.lua`
