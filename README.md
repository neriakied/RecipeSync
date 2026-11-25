# RecipeSync

**Version 1.1.0** · for Turtle WoW / OctoWoW (1.12 client)

See every profession in your guild in the normal trade skill window: who can craft what, with no linking in chat.

## Install

**With the launcher:** add this repository's GitHub link in the launcher's addon section.

**By hand:** download the ZIP (green **Code** button → **Download ZIP**) and unzip it into
`World of Warcraft\Interface\AddOns\`. Rename the folder to exactly `RecipeSync` (remove any `-main` / `-master`).
`RecipeSync.toc` must be directly inside it.

Then restart the game.

## Quick start

1. **Open each of your own profession windows once** (Enchanting too). That's how RecipeSync learns your recipes.
2. Click the **Enchanting icon on your minimap** or type **`/recipes`**, then click a profession.

## The window

* **Profession icons:** hover for the top crafters, click to open that profession in the normal trade skill window.
* **Show unconfirmed names:** shows or hides names that officers added by hand.
* **Sync Now:** checks for anything new right away. It normally happens automatically.
* **Sync with guild:** leave it empty to share with your own guild. To share with a guild you're **not** in,
  type its exact name and press Enter. This only works within your own faction.
* **Export to Sheets:** makes a table for people without the addon. Click **Select All**, press **Ctrl+C**,
  click cell **A1** in a Google Sheet and press **Ctrl+V**.

**Minimap button:** left-click opens the window, right-click opens the export, and you can drag it around the minimap.
`/recipes minimap` hides or shows it.

## The profession window

* Lists **every** recipe from the OctoWoW database, grouped by category. The dropdown filters by category,
  and the search box next to it matches recipe, reagent or player names.
* **Green** means a RecipeSync user knows it, **yellow** means only hand-added names, **grey** means nobody yet.
  **[3]** means 3 people can make it.
* Click a recipe to see reagents (with how many **you** have) and **Crafters**, with names in their class colour.
  Hand-added names have a grey **(?)**.
* **Add Name / Remove Name:** record a crafter who doesn't use the addon. **Only the top 3 guild ranks**
  (rank 0-2, e.g. Guild Master, Officer, Dragon) can do this. Everyone else sees the names but no buttons.

## How syncing works (simple version)

* **Your list:** when you open your profession window, RecipeSync writes down which recipes you know as one
  short line of text. **A whole profession fits in a single message.**
* **Logging in:** you send **one** message saying "here's what I have", with a fingerprint of each list.
  Nobody floods you with replies. If your saved info is out of date, **one** player sends you a short directory
  of who has what.
* **Only what changed:** if a fingerprint doesn't match your copy, RecipeSync asks for that list.
  Up to 12 lists are asked for in one message, and each answer is one message.
* **Offline crafters:** everyone keeps a copy of every list. If a crafter is offline, one person who has their list passes it on.
* **Hand-added names:** only accepted straight from a top-3-rank officer, checked against *your own* guild roster.
  Nobody can pretend to be an officer, and players outside the guild can't add names.
* **Clean-up:** players not seen for **15 days** are removed from the lists, the window and the export.
* **Where:** hidden addon messages on guild, party and raid. A hidden chat channel named after the sync guild is
  only used when someone from outside the guild is syncing with you. Nothing appears in your chat windows.

### Staying under the server's flood protection

* Each player sends **at most about 1 message per second** (short bursts of 3), and channel lines are at least 1.2 seconds apart.
* Big transfers pause during combat.
* Compared to 1.0: a full profession list is 1 message instead of about 12, logging in costs 1 message instead of
  one reply from every online player, and requests are bundled.
* Anyone sending more than 60 messages in 10 seconds is ignored for 5 minutes.
* Every message is size- and value-checked, and every list is fingerprint-checked.
* Scans, retries and automatic downloads all have fixed limits, so nothing can loop.

## Updating

When someone you sync with has a newer version, RecipeSync prints a message telling you to update through your
launcher or from GitHub. Versions with a different message format ignore each other until everyone updates.

Hand-added names from 1.0.x are **not** carried over (they weren't rank-checked). Officers will need to add them again.
Recipe lists from 1.0.x are kept.

## Commands

| Command | What it does |
|---|---|
| `/recipes` | open the window |
| `/recipes tail` | open a profession directly (any prefix works) |
| `/recipes guild Name` | sync with another guild (`/recipes guild` alone = your own guild) |
| `/recipes sync` | same as Sync Now |
| `/recipes export` | open the export |
| `/recipes minimap` | show or hide the minimap button |
| `/recipes auto on/off` | automatic downloads (default on) |
| `/recipes unsafe on/off` | full tooltips for items not in your item cache (default off; uncached items can disconnect 1.12 clients) |
| `/recipes forget Name` | delete a player's saved data |

## Recipe data

`Data.lua` holds 1,865 recipes across 12 professions (including Jewelcrafting and Survival). They were read from
**octowow.st/db** on 2026-11-24, with item names, icons and created items matched against the Turtle WoW server data
(github.com/Penqle/tortoise-wow).
* About 35 new crafted items aren't in either database. Those recipes show the spell icon and have no item link.
* The OctoWoW database was built from 1.17 data, so a few recipes may differ in game.
  RecipeSync still shares recipes it can't find in the database. They're listed under **Not in database**.

## Notes

* Recipes are only read when the list is unfiltered (dropdowns on "All").
* The game allows 10 chat channels. If you're in 10, syncing with another guild can't join its channel
  (your own guild still syncs).
* While the guild view is open, any extra search box the game client adds to the trade skill window is hidden.
  It comes back when you close the window.
* Replacement trade skill addons (e.g. ATSW) may cover the default window.
