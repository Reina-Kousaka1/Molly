# Guild-local Sephora status

Discord bot presence is global. Molly therefore keeps its existing global
presence and displays Sephora rotation in a single bot message inside each
guild. An administrator with Manage Server runs `/mode set value:sephora` in
the text channel where the status should appear. Molly verifies the channel's
guild and type, posts the first status immediately, and stores that message and
channel ID through the existing guild persistence boundary. Subsequent updates
edit the same message. If a status message is already configured, it remains in
its existing channel. `/mode set value:standard` updates it to Molly's normal
server status and stops Sephora rotation in that guild.

The one mixed pool contains 60 supplied statuses. Each guild receives its own
shuffle bag; successful displays do not immediately repeat, including at bag
boundaries and after failed updates. `MOLLY_SEPHORA_STATUS_INTERVAL_MS` controls
the interval in milliseconds (default 120000; minimum 60000, maximum 86400000).
There is one timer for all guilds; active rotations use their cached settings.
On guild availability after restart Molly reloads the saved mode and status
message. If the database or guild store is temporarily busy, recovery is
retried on a later interval. An
existing Sephora-mode guild without a saved status message must run `/mode set`
again in a suitable channel. Molly reports an update failure if Discord or
persistence is unavailable; changing the mode can already have succeeded.

No global presence is changed. Status messages require access to the selected
text channel and permission to send and edit Molly's messages. If the saved
message is deleted or the bot loses access, status updates fail safely and are
not recreated automatically. No deployment or production service change is
part of this source change.
