# Molly V2 — economy, modes, and personal settings

This branch extends the existing V1.2 economy additively. Standard mode is the default, existing wallet/bank balances and their canonical `E...` journal IDs remain unchanged, and no existing guild document is migrated eagerly.

## Economy commands

- `/inventory` shows only the invoking user's inventory in the current server.
- `/shop status|catalog|buy|sell|enable|disable` manages the coin shop and mining-resource exchange. The standard shop is **disabled by default**; only members with Manage Server can enable or disable it.
- `/mine` produces bounded virtual resources in standard mode. A reusable pickaxe must be purchased first; mining has a 30-second per-user cooldown. Copper ore, iron ore, and crystal shards have fixed server-wide sell values.
- `/fashion status|equip|unequip` manages owned virtual accessories. Equipment is per guild and a user cannot equip an item they do not own.
- `/mode show|set` chooses `standard` or `sephora`; changing the mode requires Manage Server. It does not erase either mode's stored state.

A standard shop purchase or resource sale updates inventory, wallet, journal and its namespaced economy receipt in one guild transaction. The canonical Money-ID scheme remains unchanged; `/transactions` and `/transaction` remain the history and lookup surfaces. A replay within the retained request window never charges or grants twice, and an expired request ID fails closed rather than running again. The shop uses a fixed code catalog rather than accepting prices from callers.

Storage and retention: account balances are not subject to an application-level account-count cap and are never evicted. The journal retains the newest 1,000 rows per guild, rotating out older history without changing balances; `/transactions` and `/transaction` can find only retained rows, so a Money ID is not a permanent lookup key. Economy idempotency receipts are stored separately from other guild receipts and retain at most 5,000 request IDs per guild across interactions and prefix-message requests. When a receipt ages out, per-request-type numeric watermarks make that request ID (and older IDs for that request type) fail with `replay_expired` instead of executing again; the original replay result is no longer available. Legacy economy receipts in `data.receipts` are read and migrated once, while unrelated receipts remain there. Inventory remains limited to 200 owners, 50 item types per user and 999 of each item. The storage service's document/frame limits still apply to the aggregate guild record. Mining is unavailable in Sephora mode.

## Virtual Sephora mode

`/sephora lookbook|try|status|clear` and the virtual entry under `/shop` provide four fictional, cosmetic looks. Selecting a look costs zero coins and writes only to the guild-isolated virtual fitting record. It does not call the money ledger, offer purchases, collect payment, or connect to a payment provider. Standard inventory, balances and settings remain stored if a guild switches modes and returns later.

## Mature-content safety

`/content show|enable|disable|channel-add|channel-remove` controls a guild setting which is off by default. A manager must first allowlist a text channel that Discord itself reports as NSFW and belonging to the same guild. At most ten channels may be allowed. Starboard fails closed for every NSFW source unless the destination is also a verified, allowlisted NSFW channel.

`ContentPolicy:authorize` rejects categories marked `explicit` or `pornographic`; `mature` requires both the guild's enabled allowlist and the user's separate opt-in. Only `general` and `non_mature` categories are otherwise accepted; unknown or unclassified categories fail closed. `/user-settings mature-on|mature-off` controls that private opt-in (off by default). `/user-settings compact-on|compact-off` controls the optional compact-response preference; `/user-settings reset` deletes the saved profile. Only users who opt into at least one preference are persisted, with a global cap of 1,000 profiles.

**Important scope limit:** this implementation does not include an image, text, or URL classifier. It cannot infer that arbitrary user-submitted content is explicit or non-explicit. The category check is an API boundary for callers that have a trustworthy category; the channel allowlist is an administrator-controlled Discord-channel gate, not an automatic moderation classifier. Attachments are not copied by starboard. Do not treat these settings as a substitute for Discord's NSFW controls, moderation, or human review.

## Developer-only observability

`/observe metrics|runtime|seaworld` is restricted to configured `MOLLY_DEVELOPER_IDS` and responds ephemerally. Metrics are aggregate in-memory command counts and handler timings, with a fixed command-cardinality cap; they contain no guild IDs, user IDs, arguments, message text, or credentials and reset on process restart. This does not add a persistent log or error-buffer service. The existing public `/health` output remains a separate non-sensitive summary.

## Storage and tests

Guild mode, shop and content policy are stored additively under `data.molly_v2.settings`. Inventory and virtual fittings live under guild-scoped V2 sections. Personal preferences use one bounded global profile collection and contain only two booleans; they are not copied into guild profiles.

Offline tests use fake guild/global stores and mocked Discord REST calls:

```sh
lua5.1 tests/economy_v2.lua
lua5.1 tests/community.lua
```

They cover disabled defaults, guild isolation, policy validation, user opt-in, replay receipts, atomic ledger/inventory operations, mining cooldowns, fashion ownership, and free virtual Sephora selections. They do not validate a live Discord permission setup or SeaWorld deployment.
