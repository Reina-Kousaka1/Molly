# Molly V2 — community settings and events

This document describes the V2 community features currently implemented in this branch. They are additive: existing guild fields such as `prefix`, economy balances, `modlog`, and `voice_system` remain compatible. New modular settings are stored under `data.molly_v2.settings`; AFK records and starboard publication receipts use separate guild-scoped V2 sections. There is no eager migration of existing guild documents; legacy economy receipts are migrated lazily by the economy ledger as documented in [v2-economy-modes.md](v2-economy-modes.md).

## Commands

All settings below are per server. Configuration commands require **Manage Server**. Molly's existing global blacklist and developer authorization remain outside this guild permission system.

- `/permissions allow|grant|deny|revoke|reset|view|list` manages command overrides. Precedence is user+channel, role+channel, user, role, channel, then server. Explicit same-specificity role conflicts deny. Developer, protected, and admin commands cannot be granted through this system. `MOLLY_DEVELOPER_IDS` remains the only source of developer access.
- `/welcome show|enable|disable|channel|message|embed-on|embed-off|embed-title|embed-description|preview`
- `/goodbye` has the same subcommands as `/welcome`.
- Welcome and goodbye templates accept only `{user}`, `{mention}`, `{server}`, and `{member_count}`. Mention parsing is restricted to the explicitly rendered member mention. Both features are disabled by default.
- `/logs show|enable|disable|channel|event` configures a per-server event channel and event categories. The log module suppresses mentions, never mirrors message contents, and logs message deletions using channel/message IDs only.
- `/afk set|clear|status` maintains a per-server status. Status text is capped at 140 characters, storage at 200 users per server, mention notices are rate-limited per channel/user, and an author's status is cleared on their next guild message. Message IDs are kept only in a bounded in-memory duplicate-suppression cache.
- `/selfroles list|join|leave|allow|disallow` provides a server allowlist. Molly verifies that the role is not `@everyone`, is not managed, does not carry powerful management/moderation permissions, and is below both the bot's role and (for configuration) the acting manager's highest role. The bot must have **Manage Roles**. Users may remove a previously allowed role even after the allowlist entry is removed.
- `/delete count:<1–100>` purges recent messages from the current text channel. The fixed `.d <count>` alias preserves the invoking message and accepts up to 99 other messages. Older messages, cross-guild channels, and unverifiable bot permissions fail closed; the command does not copy or log message contents.
- `/hackban` requires the explicit slash confirmation option. The fixed `.hb confirm <user_id> <reason>` alias requires the literal confirmation word. Both paths retain the pending-case and post-ban verification flow; a repeated message/interaction receipt does not dispatch a second ban.
- `/starboard show|enable|disable|channel|emoji|threshold|ignore|unignore` configures a reaction-based starboard. Thresholds are bounded to 1–100. Only text is copied; attachments are not mirrored. If the source channel is marked NSFW, the destination must also be marked NSFW and must be allowlisted by the separately default-off `/content` policy. The starboard destination itself is not enabled by default. See [v2-economy-modes.md](v2-economy-modes.md) for the channel allowlist, user opt-in, and classifier limitation.

## Privileged member intent

Gateway member-add/remove events are needed for automatic greetings, goodbyes, and live member-count tracking. The privileged `GUILD_MEMBERS` intent is **off by default** to avoid changing existing gateway behavior unexpectedly.

To opt in, set `MOLLY_GUILD_MEMBERS_INTENT=true` in the runtime environment and enable **Server Members Intent** in the Discord Developer Portal for the bot application. The value must be the literal `true` or `false`. Enabling only one side is not sufficient. When disabled, greeting configuration can still be saved and previewed, but automatic join/leave events will not be received.

The existing Message Content intent remains separately required for prefix commands.

## Data bounds and isolation

- Permission rules: at most 1,000 per guild; cache at most 500 guilds, with a short TTL.
- AFK statuses: at most 200 per guild, 140 message characters; in-memory duplicate and notification caches are bounded.
- Self-assignable roles and ignored starboard channels: at most 100 each per guild.
- Starboard publication records: at most 5,000 per guild. In-memory vote state is limited to 500 messages and 256 tracked voters per message. Publication records are additive under `data.molly_v2.starboard`; vote state is transient.
- Greeting, action-log, and role settings are stored per guild under `data.molly_v2.settings` and validated before writes.

No V2 module uses a process-wide lock for guild work. Economy ledger receipt retention and the 1,000-row journal rotation are described in [v2-economy-modes.md](v2-economy-modes.md); unrelated community receipts remain in their existing V2 sections.

## Discord API and safety limits

Community event tests use mocked Discord REST clients and do not contact Discord. Runtime behavior depends on the `discord.lua` API version installed by the deployment. The implementation uses its existing REST/event surface (`get_channel`, `get_channel_messages`, `get_message`, `send_message`, `edit_message`, `delete_message`, `bulk_delete_messages`, `get_roles`, `get_member`, `add_role`, `remove_role`) and lower-snake-case gateway events. Verify those methods and events against the installed dependency before rollout; the repository does not vendor `deps/` or claim that a separate upstream checkout proves the deployed version.

Discord rate limits and permission checks remain authoritative. Missing role/member/channel data fails closed. The bot needs the relevant channel and role permissions; inability to verify a channel or hierarchy does not fall back to allowing the action. Discord may not deliver member events without the privileged intent enabled in both code configuration and the application portal.

NSFW starboard safety is based on Discord's channel `nsfw` flag. Attachments are never copied. This is not a classifier for unsafe text or external URLs.

## Local verification

See [testing.md](testing.md) for the full CI, Luvit, and SeaWorld integration matrix. The CI-safe suite validates local contracts and mocked REST behavior; it does not prove Discord portal configuration or live REST permissions. No production migration, bot restart, or deployment is part of V2 development.
