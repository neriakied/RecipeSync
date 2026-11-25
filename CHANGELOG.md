# Changelog

## 1.1.0
- **Minimap button** with the Enchanting icon: left-click opens the window, right-click opens the export, and you can drag it to move it.
- **Only the top 3 guild ranks** (rank 0-2) can add or remove hand-added names. Names are only accepted straight
  from an officer, checked against your own guild roster.
- **Hand-added names from 1.0.x are discarded**, and 1.0.x messages are ignored (recipe lists are kept).
- **Much lighter syncing:**
  - A whole profession list fits in 1 message instead of about 12.
  - Logging in sends 1 message instead of triggering a reply from every online player.
  - Requests are bundled, up to 12 lists per message.
  - Sending is capped at about 1 message per second.
  - The hidden chat channel is only used when players from outside the guild are syncing.
- **Update notice:** a chat message tells you to update through the launcher or GitHub when someone runs a newer version.
- The search box in the profession window is back next to the category dropdown.

## 1.0.1
- Hides the game client's own search box in the guild profession view (it covered the checkboxes).

## 1.0.0
- First release: guild professions in the default trade skill window, OctoWoW recipe database, class-coloured
  crafters, hand-added names, Google Sheets export, sync with other guilds, 15-day clean-up.
