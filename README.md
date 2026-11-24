# RecipeSync 1.0 (Turtle WoW / OctoWoW, 1.12 client)

See every profession in your guild in the normal trade skill window: who can craft what, with no linking in chat.

## Install
Unzip so the path is `World of Warcraft\Interface\AddOns\RecipeSync\RecipeSync.toc`
(the folder must be named exactly `RecipeSync`), then restart the game.

## Quick start
1. **Open each of your own profession windows once** (Enchanting too). That's how RecipeSync learns your recipes.
2. Type **`/recipes`** and click a profession icon.

## The /recipes window
* **Profession icons**: hover for the top crafters, click to open that profession in the normal trade skill window.
* **Show unconfirmed names**: shows or hides names that were added by hand.
* **Sync Now**: checks for anything new right away. It normally happens automatically.
* **Sync with guild** (box between Sync Now and Export): leave it empty to share with your own guild.
  To share with a guild you're **not** in, type its exact name and press Enter. Everyone who uses the same
  guild name shares recipes. This only works within your own faction.
* **Export to Sheets**: makes a table for people without the addon. Click **Select All**, press **Ctrl+C**,
  click cell **A1** in a Google Sheet and press **Ctrl+V**.

## The profession window
* Lists **every** recipe from the OctoWoW database, grouped by category (the dropdown filters by category).
* **Green** means a RecipeSync user knows it, **yellow** means only hand-added names, **grey** means nobody yet.
  **[3]** means 3 people can make it.
* Click a recipe to see reagents (with how many **you** have in your bags) and **Crafters**, with names in their class colour.
  Hand-added names have a grey **(?)**.
* **Search** (top right): recipe, reagent or player name. Type "Bob" to see everything Bob can make.
* **Unconfirmed** / **Known only** checkboxes. **Add Name** / **Remove Name** record crafters who don't use the addon.

## How syncing works (simple version)
* **Your recipe list:** when you open your profession window, RecipeSync writes down which recipes you know.
  Each recipe is just a number from the OctoWoW database, so the list is tiny.
* **Saying hello:** when you log in, RecipeSync quietly tells everyone you sync with:
  "I'm here, and here's a short fingerprint of each of my recipe lists."
* **Fetching only what changed:** if your copy of someone's list doesn't match their fingerprint, RecipeSync asks for it.
  Lists that haven't changed are never sent again.
* **Everyone keeps a copy:** every RecipeSync user saves every list they receive. If a crafter is offline,
  someone who has their list passes it along, so you can still see their recipes.
* **Who's who:** RecipeSync also shares a short directory of who has which profession, so new users can catch up on everyone.
* **Hand-added names:** these are shared too. If two people change the same name, the newest change wins,
  and removals reach everyone.
* **Where messages go:** hidden addon messages over guild, party and raid, plus a hidden chat channel named after the
  sync guild. That channel is what lets players outside the guild join. It never shows in your chat windows.
* **Clean-up:** players who haven't been seen for **15 days** are removed from the lists, the window and the export.
  "Seen" means online in the guild roster, sending a message, or reported by another user.
  Hand-added names are hidden once the guild roster says that person has been offline 15+ days.
  For hand-added names of people outside your guild, there's no way to tell when they were last online, so they stay.

## Safety limits
* Sends at most about 700 bytes per second. Channel lines go at most about 1 per second, and big transfers pause in combat.
* Even a maxed profession list is only about 12 short messages.
* Anyone sending more than 120 messages in 10 seconds is ignored for 2 minutes.
* Every message is size- and value-checked, and every list is fingerprint-checked.
* Stalled transfers are dropped after 60 seconds, and passed-along lists must match what the owner last announced.
* Nobody can overwrite your own list.
* Scans, retries, automatic downloads, directory answers and resends all have fixed limits.
  Only one person answers each request, so nothing loops or floods.
* Errors are caught and printed once instead of breaking your UI.

## Commands
| | |
|---|---|
| `/recipes` | open the window |
| `/recipes tail` | open a profession directly (any prefix works) |
| `/recipes guild Name` | sync with another guild (`/recipes guild` alone = your own guild) |
| `/recipes sync` | same as Sync Now |
| `/recipes export` | open the export |
| `/recipes auto on/off` | automatic downloads (default on) |
| `/recipes unsafe on/off` | full tooltips for items not in your item cache (default off; uncached items can disconnect 1.12 clients) |
| `/recipes forget Name` | delete a player's saved data |

## Recipe data
`Data.lua` holds 1,865 recipes across 12 professions (including Jewelcrafting and Survival). They were read from
**octowow.st/db** on 2026-11-24, with item names, icons and created items matched against the Turtle WoW server
data (github.com/Penqle/tortoise-wow).
* About 35 new crafted items aren't in either database. Those recipes show the spell icon and have no item link.
* The OctoWoW forum says their database was built from 1.17 data, so a few recipes may differ in game.
  RecipeSync still shares recipes it can't find in the database. They're listed under **Not in database**.

## Notes
* Recipes are only read when the list is unfiltered (dropdowns on "All").
* The game allows 10 chat channels. If you're already in 10, RecipeSync can't join its sync channel
  (guild sync still works). Leave a channel and click Sync Now.
* Replacement trade skill addons (e.g. ATSW) may cover the default window.
