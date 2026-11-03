# Molly V2 hardening and stress report

## Scope and tested source

- Repository: `Reina-Kousaka1/Molly`
- Branch: `arena/5d5fabc5-molly` (PR #4)
- Baseline inspected: `e4b0963d0bd184eec190e1ed8e0c93f236b2a872`
- This report adds no economy feature and does not claim production readiness.
- Runtime available on the inspection host: Windows PowerShell and Node.js. The
  Windows Python app-execution alias was present but could not start. Lua 5.1,
  `luac5.1`, Luvit, repository `runtime/`, `deps/`, and an
  explicitly disposable SeaWorld test socket were absent. No production or
  Docker service was queried or changed.

## SeaWorld wire and state limits

`src/seaworld/socket_driver.lua` uses Luvit's `json.encode` to serialize the
complete request object, then writes one newline-delimited frame. The hard limit
in Molly is 1,048,576 bytes including the request newline. The response reader
rejects a line whose newline occurs after byte 1,048,576 and rejects an
unterminated receive buffer larger than that. This is a Molly transport limit;
the SeaWorld service's own configured limits were not available for inspection.

`src/persistence/guild_store.lua` stores each guild in one document and passes
the full updated `data` table to a single `update` operation. Consequently the
serialized request grows with the whole guild document. Accounts have no
application-level cap, preserving balances and avoiding a permanent account
count lockout. The bounded portions observed in source include a 1,000-row
economy journal, 5,000 economy receipts, 200 inventory owners (50 item types per
user, quantities up to 999), 1,000 moderation cases, and 200 AFK entries.
Sephora fittings are capped at 200 users, but its 5,000 receipts currently
fail closed at capacity rather than rotate. Staff directory mutations retain
request receipts in the shared `data.receipts` table without a retention cap;
this table can therefore continue growing independently of the economy receipt
cap. Guild settings are small, but this does not bound every guild document.

The driver returns `resource_limit` before writing an oversized request. The
GuildStore currently maps a failed `update` to generic `unavailable`; the user
does not receive an explicit size-limit reason. The driver closes a failed
transport, which should abandon the open transaction, but rollback-on-disconnect
has not been verified against a real SeaWorld service. Therefore the current
evidence does not establish the requested no-partial-write/recovery behavior at
the actual 1 MiB boundary.

### Size stress results

No exact serialized-size result is reported: the required Luvit `json` encoder
and disposable SeaWorld service were unavailable. Account counts alone are not
a reliable byte-size proxy because receipt fingerprints, legacy fields,
inventory, moderation reasons, and other persisted modules vary. The included
`tests/stress.lua` measures synthetic ledger growth in the CI Lua runtime but is
not represented as a SeaWorld serialization or integration measurement.

Required follow-up before merge: run an opt-in test against a disposable service
and the exact Luvit JSON encoder at 100, 500, 1,000, 5,000, and 10,000 accounts,
plus inventory/receipt/config-heavy states; record outbound request size and
response size; test the operation just below and above the frame limit, confirm
the original document and balances after failure, then restart and verify.

## Ledger rotation and benchmark

The production journal keeps the newest 1,000 entries using append followed by
`table.remove(data.journal, 1)` on overflow. The synthetic benchmark added at
`tests/stress.lua` reports elapsed time, per-append average, p95/p99, Lua heap
delta, and retained count for the existing rotation and a test-only ring-index
candidate at 100, 1,000, 10,000, and 100,000 appends. It asserts that both retain
the same oldest-to-newest window. The ring candidate is not production code.

The same script runs 100, 500, 1,000, 5,000, 10,000, and (in full mode) 100,000
distinct-user ledger operations against an in-memory store and reports throughput, average/p95/p99/
maximum operation latency, heap delta, account count, journal count, and receipt
count. This includes the actual ledger's receipt validation/retention path but
excludes socket, JSON serialization, SeaWorld commit, and process restart costs.

The first full CI attempt reached the 30-minute workflow timeout before the
100,000-operation ledger benchmark completed. GitHub canceled the job, so no
100,000 timing or throughput is reported. The CI profile is now capped at 10,000
operations; the full profile remains explicitly runnable with
`MOLLY_STRESS_FULL=1 lua5.1 tests/stress.lua`. The timeout is a failed/incomplete
stress result, not a pass, and indicates a serious scaling concern in the
synthetic full receipt-validation/eviction path.

The CI-safe Lua 5.1 benchmark ran on commit `08f66f76dc26b78f09806ff9a836db13bbf1d6ff`
in GitHub Actions run [41687517286](https://github.com/Reina-Kousaka1/Molly/actions/runs/41687517286).
Measured values:

| Synthetic workload | Elapsed | Throughput / average | p95 / p99 (max for ledger) | Lua heap delta* | State after run |
| --- | ---: | ---: | ---: | ---: | --- |
| Journal `table.remove`, 100,000 appends | 0.921 s | 9.208 µs/append | 9 / 15 µs p95/p99 | 2,064.1 KiB | 1,000 retained |
| Test-only ring index, 100,000 appends | 0.151 s | 1.507 µs/append | 1 / 1 µs p95/p99 | 2,064.1 KiB | 1,000 retained |
| Ledger, 100 operations | 0.009 s | 11,041 ops/s; 0.091 ms/op | 0.127 / 0.131 / 0.140 ms | 527.9 KiB | 100 accounts, 100 journal, 100 receipts |
| Ledger, 500 operations | 0.146 s | 3,416 ops/s; 0.293 ms/op | 0.514 / 0.540 / 0.551 ms | 2,621.2 KiB | 500 accounts, 500 journal, 500 receipts |
| Ledger, 1,000 operations | 0.550 s | 1,817 ops/s; 0.550 ms/op | 1.007 / 1.055 / 1.113 ms | 5,246.5 KiB | 1,000 accounts, 1,000 journal, 1,000 receipts |
| Ledger, 5,000 operations | 13.317 s | 376 ops/s; 2.663 ms/op | 5.030 / 5.275 / 7.032 ms | -5,006.8 KiB | 5,000 accounts, 1,000 journal, 5,000 receipts |
| Ledger, 10,000 operations | 114.470 s | 87 ops/s; 11.447 ms/op | 22.566 / 28.213 / 34.267 ms | 3,321.1 KiB | 10,000 accounts, 1,000 journal, 5,000 receipts |

*Heap deltas include per-operation latency sample arrays and automatic Lua GC;
they are not isolated retained-state memory. The negative delta at 5,000 is a
GC effect and demonstrates that these values are not reliable retained-memory
measurements. These are synthetic in-memory Lua 5.1 measurements, not SeaWorld
request size, persistence latency, or production throughput. The 100,000-operation full ledger attempt was canceled by the
30-minute CI timeout without completing and has no valid timing result. The
114-second 10,000-operation run and failed full run expose material scaling risk
in repeated receipt validation/oldest-entry scans.

The test-only ring was about 6.1x faster for the isolated 100,000-append loop, but
the existing rotation took under one second and contributed only a tiny part of
the 114-second 10,000-operation ledger run. No production ring rewrite was made:
the isolated speedup is not evidence of a material end-to-end gain, and changing
the persisted journal representation would require separate order/lookup and
backward-compatibility proof.

## Receipt retention and replay semantics

The inspected implementation retains at most 5,000 economy receipt envelopes.
It keeps separate numeric watermarks for `interaction` and `message` IDs and
compares decimal strings without converting them to floating-point numbers or
interpreting Snowflakes as timestamps. An evicted request at or below its
request-type watermark returns `replay_expired`; retained requests compare the
structured operation fingerprint and return `replay_conflict` on mismatch.
This preserves retry rejection after process reload without retaining every
receipt. Transaction lookup only covers the bounded retained journal.

Legacy economy receipts are migrated into the bounded envelope set once. The
source iterates a Lua map during migration, then uses numeric ID ordering and a
request-type tie-break for retention. No SeaWorld-backed migration with
overlapping legacy/current receipt data has been run in this environment.
Non-economy entries in `data.receipts` are intentionally retained for backward
compatibility; staff receipts are currently unbounded. Sephora uses a separate
hard cap and does not share economy watermarks.

## Concurrency, commit uncertainty, and recovery

GuildStore uses a process-local busy flag keyed by guild and a forked
connection/session for each operation. Different guilds do not share a global
busy lock. Before each write it begins a SeaWorld transaction and rereads the
guild document inside that transaction. Failures before commit attempt rollback;
commit acknowledgement failure returns `outcome_unknown`, and an idempotent
retry can replay a persisted receipt if the first commit succeeded.

The repository has mock tests for guild isolation, per-guild session ownership,
rollback, lost commit acknowledgement, and retry after an unknown commit. No
real SeaWorld concurrency test was possible here. Cross-process lost-update
protection depends on SeaWorld's transaction isolation/locking semantics and is
not proven by Molly's process-local busy flag or mock tests.

## Luvit, Lavalink, and integration coverage

The existing `tests/run_luvit.sh` invokes Lavalink client tests with mocked
network transports and Discord registration tests with a mocked client. It
requires Luvit, the Luvit `json` module, and `discord.lua` on `package.path`.
Those dependencies were absent, so neither test was executed. No Discord token
or live Lavalink endpoint was used. The existing `tests/run_integration.sh`
requires an explicit disposable SeaWorld socket and confirmation variable; no
such socket was set, so no SeaWorld integration test was started.

GitHub Actions run 41687517286 passed the Lua 5.1 syntax check, all 12 plain
Lua suites (159 tests, zero failures), the CI-profile synthetic stress checks,
the Python environment-transfer test (4 checks, zero failures), and diff
whitespace validation. The separate 100,000-operation full profile was
attempted in run 41681560738 and canceled at the 30-minute job timeout; it is not
counted as a passing test. The test classification and reproduction commands
remain in `docs/testing.md`.

## Risks and merge blockers

1. **Guild document growth can permanently block writes.** A one-document,
   one-frame persistence model has no safe way in Molly to split a guild state
   larger than 1 MiB. There is no verified SeaWorld-side oversized-document
   behavior or rollback test. A durable remedy needs a SeaWorld-supported
   multi-document/partitioned transaction design or a hard admission bound with
   proven semantics; neither is introduced here.
2. **Some persisted collections have unbounded or fail-closed growth.** Shared
   staff receipts are unbounded. Sephora receipts stop accepting new fittings
   at 5,000. These can contribute to guild document growth or become permanent
   feature-capacity failures.
3. **Production transaction isolation is unverified.** In-process guild
   isolation is covered by tests, but SeaWorld's cross-session/cross-process
   behavior, timeout recovery, and disconnect rollback require a disposable
   service test.
4. **Luvit-only test suites were not run locally.** The synthetic benchmark and
   Lua 5.1 CI can cover ledger CPU behavior, but not Luvit JSON frame sizing,
   socket behavior, Discord library integration, or real persistence latency.

### Architecture direction if the frame boundary is confirmed

Do not silently truncate accounts, balances, inventory, receipts, or journal
data. First establish SeaWorld's supported transactional primitives and
document-size limits. If one guild document cannot safely grow indefinitely,
the future design should partition high-growth data (for example, account
records and historical receipts) into deterministic guild-scoped records while
keeping balances and request receipts in a transactionally consistent unit.
Migration must be additive, restartable, and dual-read/verified before any
cutover; no such migration is safe to design from the Molly adapter alone.

## Final measured results

Most recent CI-tested commit: `08f66f76dc26b78f09806ff9a836db13bbf1d6ff`.
Real SeaWorld sizing, concurrency, and Luvit integration remain explicitly
unverified until the disposable dependencies described above are provided.
