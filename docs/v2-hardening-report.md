# Persistence-growth and SeaWorld framing hardening report

## Scope and evidence boundary

- Repository: `Reina-Kousaka1/Molly`
- Branch: `arena/5d5fabc5-molly`
- PR: [#4](https://github.com/Reina-Kousaka1/Molly/pull/4), still open; this work does not merge it.
- Implementation and test commit: `d923d46` (`Bound persisted receipts and guard SeaWorld frames`).
- Tested source: that commit, based on PR head `335a22730a32a7fb9494aa4d487a2123a3d7cdcc`.
- Verification date: 2026-11-04.

The results distinguish three different things: Lua unit tests with isolated
mocks, synthetic documents encoded by upstream Luvit's JSON module, and live
SeaWorld behavior. The first two were exercised. No SeaWorld socket/service,
disposable database, production document, or cross-process concurrency test was
available. Therefore Molly's configured frame cap and mock rollback behavior
are verified, but SeaWorld's own frame limit, transaction isolation, and
rollback-after-disconnect behavior are not.

## Persistence-growth audit

| Persisted area | Current bound/retention | Migration and replay behavior | Growth concern |
| --- | --- | --- | --- |
| Economy accounts and balances | No account-count cap; balances are never evicted. | Existing IDs and balances remain intact. | Unbounded account cardinality can exceed one update frame. |
| Economy journal | Newest 1,000 rows per guild. | Rotation changes history only, not balances; lookup is limited to retained rows. | Bounded, but rotating the production array still uses `table.remove`. |
| Economy receipts | Newest 1,000 per guild, across interaction and prefix-message IDs. | Legacy economy receipt envelopes migrate lazily. Numeric per-type watermarks cause expired IDs to fail closed as `replay_expired`; retained IDs still replay or conflict by operation fingerprint. Unrelated legacy receipt values are preserved. | Lowered from 5,000 after frame-size profiling; replay results outside the window are intentionally unavailable. |
| Staff directory | Up to 200 staff entries; up to 50 notes per staff member, 500 bytes each; newest 1,000 staff receipts. | Only a legacy `data.receipts` value with the exact `{staff_id}` shape is migrated. Other receipt values are left in place. Retained duplicate requests validate staff, actor, action, and note before replay. | Staff notes are bounded but their combined worst case is larger than a single frame; notes are not silently pruned. |
| Sephora | Up to 200 fittings; newest 5,000 receipts. | Existing receipts are migrated into a ring. Expired IDs fail closed with `replay_expired`, rather than stopping all future fittings at a permanent capacity ceiling. | The 5,000-receipt section consumes nearly half a MiB in the synthetic maximum-state profile. |
| Moderation cases | Up to 1,000 cases; reason history up to 20 entries. | Case receipts are compact `{case_id}` references. Legacy full case receipt values are compacted on replay after validating the referenced case. Other receipt values are not generically deleted. | Long reasons/history contribute materially to aggregate document size. |
| Global blacklist | Active blacklist entries are not automatically evicted; newest 1,000 mutation receipts. | Existing matching receipt replays remain idempotent; expired IDs fail closed. | Active entries remain intentionally unbounded to avoid silently removing administrative state. |
| Lifecycle | One pending marker; newest 1,000 restart/update receipts. | Duplicate requests remain idempotent within the retained window; expired IDs fail closed. Cancel retains its existing behavior of removing the matching receipt. | Bounded. |
| Inventory | Up to 200 owners, 50 item types per owner, quantity 999 per item. | Existing inventory is retained; capacity failures do not evict items. | Bounded cardinality, but can still add hundreds of KiB to a guild document. |
| Guild settings | Schema-bounded strings and lists (for example, up to 100 self-assignable roles and ignored starboard channels). | Settings updates preserve unrelated V1.2 fields. | Small by themselves; included in the aggregate-size profile below. |
| Global user settings | At most 1,000 saved profiles, two boolean preferences each; default-only profiles are removed. | Existing profiles remain readable and reset deletes only that user's profile. | Bounded and small. |
| AFK and starboard | AFK: 200 records, 140-character message. Starboard publication records: 5,000 per guild. | These are distinct feature sections, not receipt maps. | Bound but contribute to the full guild document. |
| Transient caches | AFK duplicate IDs 512, notice keys 500; starboard cache 500 messages/256 users per message; ledger receipt index at most 8 guilds. | Process-local only; rebuilt/expired as designed. | Not persisted, but their limits avoid process-memory growth. |

### Receipt migration and data preservation

`src/persistence/receipt_window.lua` maintains a bounded receipt map, ring order,
count, and decimal-ID watermark. Warm lookups and eviction do not scan the
receipt map. Initial legacy migration sorts IDs once to choose a deterministic
retained window. The ledger's separate migration recognizes only its economy
receipt envelopes; the staff migration recognizes only the exact old staff
receipt shape. Unknown and non-staff entries in the shared legacy
`data.receipts` map are not swept into a generic cleanup. Moderation compaction
replaces only validated case receipts with compact references. These rules
preserve V1.2 data where its ownership can be established and avoid silently
losing unrelated receipts.

The bounded windows necessarily narrow *how long* a prior result remains
available. They do not permit an expired ID to repeat its mutation: watermarks
reject expired IDs instead. The prior result itself can no longer be replayed
once evicted. Active blacklist state, balances, inventory, staff notes, and
other user data are not evicted as a frame-size workaround.

## SeaWorld JSON frame boundary

`src/seaworld/socket_driver.lua` measures the serialized request after copying
the payload and encoding the complete envelope. Molly's configured limit is
exactly **1,048,576 bytes**, including the newline delimiter. A request larger
than that returns `resource_limit` before any write. The response reader accepts
a newline at byte 1,048,576 and rejects a later newline or an unterminated buffer
that grows past the same limit.

The value above is the client's configured ceiling, not a verified SeaWorld
server setting. The server implementation/configuration was not available to
inspect. The exact-byte tests establish client behavior, not that the service
will accept a frame at that size.

### Isolated request/response and rollback tests

`tests/seaworld_driver.lua` builds exact-size frames using its test JSON
encoder and verifies exact-limit acceptance, one-byte-over rejection before a
socket write, UTF-8 byte counting, and exact/oversized responses. It exercises
`resource_limit` propagation through the connector and GuildStore. With an
isolated transaction mock, an earlier mock write is discarded when the
oversized update fails and the store rolls the still-open transaction back.

`tests/run_ci.sh` passed these isolated cases. Separately,
`tests/seaworld_luvit_frames.lua` was run with upstream Luvit's JSON encoder: it
accepted a 1,048,576-byte request including newline, rejected a +1-byte request
without writing it, and checked exact/oversized response frames. The mock tests
do not prove SeaWorld's rollback behavior or real server-side frame limits.

### Synthetic serialized document sizes

The following frames use upstream Luvit's JSON encoder and include the update
envelope and newline. They are synthetic persisted-document shapes, not
measurements from SeaWorld:

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

At 5,000 ledger operations the synthetic frame leaves little room for other
guild data; at 10,000 it exceeds Molly's configured frame limit. Some independent
maximum-shape sections are themselves too large for one update frame. The
preflight protects against sending such an update and returns an explicit error,
but it does not make the data fit or partition it. A large existing guild may
therefore become unable to perform any write that requires the whole document.
These profiles are not a prediction of every production document and do not
establish a SeaWorld limit.

## Ledger receipt-scan cost and benchmark

The ledger now keeps an eight-guild bounded in-process receipt index, with a
persisted generation value used to detect changes. Successful commits update
the index from the bounded receipt delta; cache misses and generation changes
rebuild it. The test suite covers replay after reload, expired-ID rejection,
legacy migration, index invalidation, and bounded cache cardinality. The
instrumented synthetic profile recorded **zero receipt-map iteration visits**
after index warmup.

| Direct synthetic ledger profile | Elapsed |
| --- | ---: |
| 100 operations | 0.004077 s |
| 500 operations | 0.018401 s |
| 1,000 operations | 0.038359 s |
| 5,000 operations | 0.305608 s |
| 10,000 operations | 0.604973 s |

These are in-memory Lua measurements and do not include JSON encoding, socket
I/O, SeaWorld commits, or process restarts. The earlier branch benchmark took
114.470 seconds for 10,000 operations with the prior receipt-scan path; treat
the figures as directional rather than a controlled same-host comparison.

The latest full stress run on the tested source completed 100,000 ledger
operations in **11.088 seconds** (9,018.7 operations/second; mean 0.111 ms,
p95 0.182 ms, p99 0.320 ms, maximum 11.756 ms). It ended with 100,000 accounts,
1,000 journal rows, and 1,000 receipts. The 100,000-append journal microbenchmark
measured `table.remove` at 1.038 seconds versus 0.064 seconds for a test-only
ring index. The ring index is not production journal code; no persisted journal
representation change was made.

## Test results and what remains unverified

- `LUA_BIN=/tmp/molly-lua51/src/lua LUAC_BIN=/tmp/molly-lua51/src/luac PYTHON_BIN=python3 tests/run_ci.sh` — passed all suites: 174 Lua assertions/cases across the suites plus 4 Python checks (178 reported checks total), zero failures. The CI stress profile reaches 10,000 ledger operations; the journal microbenchmark reaches 100,000 appends.
- `MOLLY_STRESS_FULL=1 /tmp/molly-lua51/src/lua tests/stress.lua` — passed the 100,000-operation synthetic profile; latest timings are recorded above.
- Actual upstream Luvit JSON frame test — passed at exactly 1,048,576 bytes including newline and rejected +1 byte. The Luvit JSON module and runner lived in temporary build paths and are not committed.
- Lavalink client mocks — 4/4 passed with Luvit's `json` module and `LUA_PATH` configured.
- The complete `tests/run_luvit.sh` runner was not run to completion because `discord.lua` was unavailable. No Discord login, live Lavalink connection, or SeaWorld integration test ran.
- `git diff --check` — passed.

No SeaWorld service was used to verify transaction rollback, cross-session or
cross-process isolation, oversized-document rejection, or actual frame sizing.
A one-document, one-frame persistence model still has a hard aggregate-growth
risk. Durable partitioning needs SeaWorld-supported transactional semantics and
an additive, restartable migration; this repository does not claim or implement
that service-level migration.
