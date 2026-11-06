# Persistence-growth and SeaWorld framing hardening report

## Scope and evidence boundary

- Repository: `Reina-Kousaka1/Molly`
- Branch: `arena/5d5fabc5-molly`
- PR: [#4](https://github.com/Reina-Kousaka1/Molly/pull/4), open against `main`; this work does not merge it.
- Verification date: 2026-11-04.
- Baseline PR head: `85eca7ef55f228ae9d982880b849d9ce0bd128ed`; checks also include the hardening changes described here.
- SeaWorld repository access was read-only. No SeaWorld source, service, database, `.env`, or production data was changed or written.

The results distinguish isolated Lua mocks, synthetic data encoded with the upstream Luvit JSON implementation, and a real SeaWorld service. The mock and synthetic checks ran; no real service integration ran. A client-side cap and mock rollback tests do not establish a server-side frame limit, transaction isolation, or rollback-on-disconnect behavior.

### Concrete SeaWorld protocol limitation

The official [`Reina-Kousaka1/seaworld.db`](https://github.com/Reina-Kousaka1/seaworld.db) source inspected on 2026-11-04 was at commit `d6589e61564c91e2e013df69a98d0544e3026032`. Its [driver guide](https://github.com/Reina-Kousaka1/seaworld.db/blob/d6589e61564c91e2e013df69a98d0544e3026032/docs/drivers.md) describes an embedded engine, with no network server or selected network/FFI protocol. Its [public API](https://github.com/Reina-Kousaka1/seaworld.db/blob/d6589e61564c91e2e013df69a98d0544e3026032/docs/public-api.md) is transport-neutral; request IDs are correlation identifiers, not durable deduplication. The [compatibility contract](https://github.com/Reina-Kousaka1/seaworld.db/blob/d6589e61564c91e2e013df69a98d0544e3026032/docs/compatibility-contract.md) documents core-engine limits (16 MiB encoded documents, 17 MiB records, and transactions up to 10,000 operations / 64 MiB encoded operation data). Those limits do **not** define a socket frame cap or prove the semantics of Molly's custom socket service.

Molly's [`ops/seaworld-molly.service`](../ops/seaworld-molly.service) refers to an external `seaworld-local` binary and a Unix socket. That binary and its socket contract are absent from the official `seaworld.db` source. No compatible, explicitly disposable integration endpoint was available, so no real-service test was attempted. The client's 1 MiB limit is retained conservatively; the engine's larger embedded document limit is not grounds to raise it. No sharding or schema migration is claimed: Molly currently writes one guild document (`set={data=data}`), and a safe partitioning migration depends on server-side transaction and compatibility guarantees that are not available.

## Persistence-growth audit

| Persisted area | Current bound/retention | Migration and replay behavior | Growth concern |
| --- | --- | --- | --- |
| Economy accounts and balances | No account-count cap; balances are never evicted. | Existing IDs and balances remain intact. | Unbounded account cardinality can exceed one update frame. |
| Economy journal | Newest 1,000 rows per guild. | Rotation changes history only, not balances; lookup is limited to retained rows. | Bounded, but production rotation still uses `table.remove`. |
| Economy receipts | Newest 1,000 per guild across interaction and prefix-message IDs. | Legacy economy receipt envelopes migrate lazily. Per-type decimal watermarks make expired IDs fail closed as `replay_expired`; retained IDs replay or conflict by full operation fingerprint. Unrelated legacy receipt values are preserved. | The bounded window narrows result replay, not mutation safety: expired IDs cannot repeat the mutation. |
| Staff directory | Up to 200 staff entries; up to 50 notes per staff member, each at most 500 bytes; newest 1,000 staff receipts. | Only the exact legacy `{staff_id}` receipt shape migrates. Other shared `data.receipts` values are preserved. Retained duplicates validate staff, actor, action, and note before replay. | Notes are bounded individually but their aggregate worst case exceeds one frame; no silent pruning. |
| Sephora | Up to 200 fittings; newest 5,000 receipts. | Existing receipts migrate into a ring. Expired IDs fail closed instead of blocking all future fittings at a permanent capacity ceiling. | The 5,000-receipt section is about half a MiB in the synthetic profile. |
| Moderation cases | Up to 1,000 cases; up to 20 reason-history entries per case. | Case receipts are compact `{case_id}` references. A legacy full receipt is compacted only after validating its referenced case. Other receipts are not generically deleted. | Long reasons/history contribute materially to aggregate document size. |
| Global blacklist | Active entries are not automatically evicted; newest 1,000 mutation receipts. | Matching retained receipts replay idempotently; expired IDs fail closed. | Active entries remain intentionally unbounded to avoid silently removing administrative state. |
| Lifecycle | One pending marker; newest 1,000 restart/update receipts. | Duplicate requests remain idempotent within the retained window; expired IDs fail closed. Cancel keeps its existing matching-receipt behavior. | Bounded. |
| Inventory | Up to 200 owners, 50 item types per owner, quantity 999 per item. | Existing inventory is retained; capacity failures do not evict items. | Bounded cardinality, but still contributes hundreds of KiB in a synthetic maximum. |
| Guild settings and content policy | Schema-bounded strings/lists (for example, up to 100 self-assignable roles, 100 ignored starboard channels, and 10 mature-content channels). | Updates preserve unrelated V1.2 fields. | Small individually; included in the aggregate profile. |
| Permission rules | Up to 1,000 rules per guild; command names and IDs are length-validated. | Updates/removals are guild-scoped and preserve unrelated rules. | Bounded, but part of the same whole-guild document. |
| Dynamic voice | Up to 100 temporary rooms per guild. | Existing tracked rooms are retained until their normal cleanup; no unrelated room record is evicted to admit another. | Bounded persisted room list; member/guild tracking and pending-event limits are process-local. |
| Music panel | One persisted panel-message record per guild. | Reuses the stored message and recreates it only after a confirmed missing-message response. | Bounded persisted record; the 500-guild panel cache is process-local. |
| Global user settings | At most 1,000 profiles, two boolean preferences each; default-only profiles are removed. | Existing profiles remain readable; reset deletes only the selected profile. | Bounded and small. |
| AFK and starboard | AFK: 200 records with 140-character messages. Starboard publication records: 5,000 per guild. | Feature state remains separate from receipt maps; starboard refuses a new record at capacity. | Bounded but contributes to the full guild document. |
| Opaque/legacy data | Unknown root fields and unrelated legacy receipts are preserved rather than guessed at or deleted. | No automatic migration claims ownership of unknown values. | Their size may be unbounded; if the resulting update exceeds the frame cap, Molly fails closed. |
| Transient caches | AFK duplicate IDs 512, notice keys 500; starboard cache 500 messages / 256 users per message; ledger receipt index at most 8 guilds; voice caches have fixed guild/member/event limits. | Process-local, rebuilt or expired as designed. | Not persisted; the explicit limits avoid process-memory growth. |

### Receipt migration and data preservation

`src/persistence/receipt_window.lua` maintains a bounded receipt map, ring order, count, and decimal-ID watermark. Warm lookups and eviction do not scan the receipt map; initial legacy migration sorts IDs once to choose a deterministic retained window. The ledger recognizes only its economy receipt envelopes, staff migration recognizes only the exact old staff receipt shape, and moderation compacts only validated case receipts. Unknown and non-staff entries in the shared legacy `data.receipts` map are not swept into generic cleanup. These rules preserve V1.2 data where ownership can be established and avoid silently losing unrelated receipts.

The windows necessarily narrow how long a prior *result* remains available. They do not permit an expired ID to repeat its mutation: watermarks reject it instead. Active blacklist state, balances, inventory, staff notes, and other user data are not evicted as a frame-size workaround. Molly's local receipt behavior also does not make a SeaWorld `request_id` a server-side deduplication key. The connector's transaction convenience path now reports `outcome_unknown` on failed or throwing commit/rollback acknowledgements rather than encouraging a retry.

## SeaWorld JSON frame boundary and failure handling

`src/seaworld/socket_driver.lua` serializes the complete request envelope before opening the socket or consuming a request ID. The measured value is the actual JSON string in bytes plus its newline delimiter; UTF-8 is therefore counted in bytes, not code points. Molly's configured maximum is **1,048,576 bytes** including newline:

- 1,048,575-byte request: accepted and written.
- 1,048,576-byte request: accepted and written.
- 1,048,577-byte request: rejected as `resource_limit` before connect/write/request-ID allocation.
- Responses at limit minus one and exact limit are accepted; an oversized response is rejected. The reader bounds accumulated partial data and rejects unexpected trailing frames.

The client returns `serialization_failed` before transport on an encoder error. In a live transaction, local preflight failures and structured server application errors preserve the transaction so the store can explicitly roll it back. Stores preserve `resource_limit` and `serialization_failed`, fail closed on other persistence errors, and report `outcome_unknown` if a write/transaction acknowledgement is ambiguous or rollback is not acknowledged. Once a mutating request may have reached the server, disconnect, timeout, malformed/missing acknowledgement, or commit failure is not blindly retried. The driver request ID is correlation only. These are client-side guarantees and mock assertions, not evidence that an unknown server rolls back on disconnect.

### Isolated and actual-encoder tests

`tests/seaworld_driver.lua` uses an isolated mock transport and JSON fixture encoder. It checks exact request/response byte boundaries, UTF-8 byte counting, rejection before opening a transport, serialization failure, active-transaction rollback after preflight or server `resource_limit`, lost write acknowledgement without retry/commit, and no commit after a rejected update. Store tests cover both guild/global `resource_limit`, serialization failure, unknown commit acknowledgement, and failed rollback acknowledgement.

`tests/seaworld_luvit_frames.lua` ran with the source-built Luvit runner's actual JSON implementation. It passed request and response boundary checks at 1,048,575, 1,048,576, and 1,048,577 bytes, including a UTF-8 request. This confirms the client's encoder measurement against that JSON implementation; it does not test a SeaWorld service.

### Synthetic serialized document sizes

These frames use upstream Luvit's JSON encoder and include the update envelope and newline. They are synthetic document shapes, not SeaWorld measurements:

| Synthetic guild state | Encoded request frame bytes |
| --- | ---: |
| 100 ledger operations/accounts | 63,309 |
| 500 ledger operations/accounts | 315,679 |
| 1,000 ledger operations/accounts | 631,181 |
| 2,000 ledger operations/accounts | 717,014 |
| 5,000 ledger operations/accounts | 972,171 |
| 10,000 ledger operations/accounts | 1,397,172 |
| Staff notes plus 1,000 staff receipts | 5,654,437 |
| 1,000 cases with maximum-length reasons and compact receipts | 684,043 |
| Inventory at 200 owners, 50 item types each | 410,528 |
| Sephora fittings plus 5,000 receipts | 514,493 |
| Maximum-length guild settings profile | 13,132 |
| 1,000 global user settings profiles | 69,164 |
| Combined staff/cases/inventory/Sephora/settings document | 7,275,493 |

At 5,000 ledger operations the synthetic frame leaves little room for other guild data; at 10,000 it exceeds Molly's configured frame limit. Some independent maximum-shape sections are themselves too large for a single update. Preflight prevents sending an oversized update and returns an explicit error; it does not make the data fit or partition it. An existing large guild may eventually be unable to perform writes that require rewriting the whole document. These profiles are not production predictions and establish no SeaWorld limit.

## Receipt-scan and stress evidence

The ledger keeps an eight-guild bounded in-process receipt index and uses a persisted generation value to detect changes. Successful commits update the index from the bounded receipt delta; cache misses and generation changes rebuild it. Unit tests cover replay after reload, expired-ID rejection, legacy migration, index invalidation, and bounded cache cardinality, including avoiding full receipt-map rescans after warmup.

A fresh full synthetic stress run on 2026-11-04 completed 100,000 ledger operations in **20.155 seconds** (**4,961.5 operations/second**; mean 0.202 ms, p95 0.302 ms, p99 0.474 ms, maximum 15.374 ms). It ended with 100,000 accounts, 1,000 journal rows, and 1,000 receipts. This was an in-memory Lua benchmark: it does not include JSON encoding, socket I/O, SeaWorld commits, or restarts, and is not a persistence-throughput claim.

The 100,000-append synthetic journal microbenchmark measured `table.remove` at 2.433 seconds versus 0.084 seconds for a test-only ring index. The ring index is not production journal code; no persisted journal representation change was made. Receipt retention checks also passed for separate message/interaction watermarks, post-reload expiry, retained replay/conflict, and legacy migration/overlap.

## Test results and remaining verification

- `LUA_BIN=/tmp/molly-lua51/build/lua LUAC_BIN=/tmp/molly-lua51/build/luac tests/run_ci.sh` — passed on PUC Lua 5.1.5. It parsed `molly.lua` and all Lua files under `src/` and `tests/`, passed **182 named Lua cases**, the CI stress profile through 10,000 ledger operations and 100,000 journal appends, and **4 Python configuration checks**. The Lua cases include the new frame, rollback, lost-acknowledgement, and unknown-commit tests.
- `MOLLY_STRESS_FULL=1 /tmp/molly-lua51/build/lua tests/stress.lua` — passed the full 100,000-operation synthetic profile; latest timings are recorded above.
- Luvit runner (source-built Luvi v2.15.0 with upstream Luvit's JSON module) — frame checks passed at all three byte sizes; the four Lavalink client mock tests passed. `tests/run_luvit.sh` then stopped at `tests/discord_registration.lua` because the required `discord.lua` dependency is not installed. The complete runner is therefore **not** verified; no Discord login occurred.
- Real SeaWorld socket integration — **not run**: no compatible service contract/binary or explicitly disposable test socket was available. No production or unknown socket was contacted; no cross-process concurrency test ran.
- `git diff --check` — passed after the final store-acknowledgement test additions.

## Remaining risk

A one-document, one-frame persistence model still has a hard aggregate-growth risk. The client correctly rejects requests that exceed its cap, but this may make future mutations unavailable while preserving existing data. The public embedded SeaWorld API cannot validate Molly's custom socket framing, atomicity, transaction isolation, cross-process behavior, or disconnect rollback. Before any production rollout or limit change, obtain the actual socket-service contract and a safely isolated disposable integration server. Until then, keep the cap, fail closed, do not blindly retry ambiguous writes, do not delete history, and do not claim real integration or a validated sharding migration.
