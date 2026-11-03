# Molly command foundation

The command registry rejects duplicates and `/help` is generated from the
registered commands. The Discord adapter carries the interaction member's
effective permission string into the command context. It checks Discord's
administrator, ban, manage-messages and manage-guild permissions without
rounding the decimal bitfield. Sensitive responses are ephemeral. Unknown
permissions, missing membership data and unverifiable role hierarchy fail
closed. Staff-directory edits and warning actions compare the actor's and
bot's highest roles against the target using current Discord REST data.

At startup the command synchronizer only adds missing global commands. It
never deletes or patches remote commands. A conflicting existing name/schema
stops the entire addition preflight and disables the local command callbacks
until the discrepancy is reviewed. The running bot and its Discord registration
have not been deployed or tested with a real account in this workspace.

Moderation currently includes warnings, case lookup/list, reason history,
warning removal, recent statistics, modlog channel configuration and
`/hackban`. Cases have guild-local Molly IDs (`C1`, `C2`, ...), never database
IDs. A hackban requires an explicit confirmation, valid Discord user ID,
actor and bot ban permissions, owner check, and a hierarchy check when the
target is a current member. For non-members, Discord's explicit unknown-member
response is required. The pending case is committed before the REST request;
Molly confirms the user is banned using Discord's ban lookup before marking the
case complete. An ambiguous response remains visible as pending/unknown and must be reconciled
before retrying. Molly does not dispatch the same interaction a second time;
the Discord HTTP dependency can itself retry a request after a reused
connection closes. A saved
case is retained when the configured modlog channel is absent or delivery fails.
This does not yet capture external moderation actions or gateway message events.

The staff directory tracks membership and notes only; it does not manage
Discord roles. Staff commands require `MANAGE_GUILD`; notes are only returned
ephemerally to authorized users. Removed staff entries and notes are retained.
There is no invented promotion ladder or application system.

Each guild has one Molly-specific collection containing a single document for
accounts, cases, staff, the modlog channel and receipts. The Molly persistence
boundary resolves its ID, opens a SeaWorld transaction, reads the current
document inside that transaction and commits the complete change once. The
document ID is internal and is not displayed to users. One in-process store
guard rejects overlapping work; the SeaWorld service serializes transactions
across connections. Wallet and bank are separate. Transfers, rewards, journal
entries and interaction receipts commit together. Receipt IDs prevent replay of
the *same Discord interaction*; a newly submitted command is a new interaction.
After an uncertain commit, users must check balance/history before retrying.
There is no promise of exactly-once delivery across different interactions.

Balances are nonnegative integer coins capped at 1,000,000,000,000 per pocket.
Current configurable-in-code rewards are daily 100 coins/24h, weekly 500/7d,
and work 20/1h; a backward clock fails closed. The initial bounded model allows
200 accounts, 1,000 economy entries, 1,000 moderation cases and 50 notes per
staff record; the transport's 1 MiB frame limit may be reached earlier. It
does not prune receipts automatically: capacity errors require a deliberate
future migration/retention policy. Transactions and staff/case history are
limited when displayed, and no SeaWorld storage internals are exposed.

Music commands are registered in `molly.lua`: `/play`, playback controls,
queue inspection/reordering, `/nowplaying`, and the persistent `/music-panel`.
Music sessions are isolated by guild, require a verified Discord voice handshake,
cap active sessions at 500, upcoming tracks at 50 (25 added per request, with at
most 100 inspected), and normalize track metadata. Gateway callbacks and panel
configuration caches have hard size limits; voice handshake events coalesce to
the latest state, and saturated Lavalink callback queues trigger bounded
playback recovery. The music panel only recreates a missing message after a
confirmed Discord 404; a permission or transport failure does not create a
duplicate. Playback still requires a configured and
reachable Lavalink v4 service, and the deployment's `discord.lua` voice/REST
contract must be verified before rollout.

`/voice` configures Join-to-Create rooms and owner controls. It verifies a voice
trigger inside a same-guild category, stores only rooms Molly created, caps
those temporary rooms at 100 per guild, and deletes an empty room only when
Discord confirms the REST operation. Runtime voice tracking is capped at 500
guilds and 5,000 active members per guild; pending callbacks and move-suppression
records are bounded. If a membership snapshot overflows or a callback/move
buffer fills, cleanup fails closed until a fresh complete snapshot is received.
Repeated trigger events do not create extra rooms.

Presence rotation has 24 local texts, one writer and a 120-second interval;
it performs no database queries and stops on shutdown.

Run offline checks with `lua tests/test.lua`, `lua tests/sprint.lua`,
`lua tests/music_voice.lua`, `lua tests/economy_v2.lua`, `lua tests/observability.lua`,
`./runtime/luvit tests/sprint.lua` and `./runtime/luvit tests/discord_registration.lua`.
`tests/economy_integration.lua` requires a separately started local SeaWorld
service and a disposable database; it never selects a production path.
