# SeaWorld to PreppyDB Cutover Readiness V3

Status: NOT READY. This work adds reviewable logical inventory capabilities and
isolated tests. It does not authorize or perform a database cutover, and it
does not qualify production data, a Raspberry Pi, or physical power-loss
durability.

## Repository and branch basis

| Repository | Isolated branch | Starting revision | Dependency |
|---|---|---|---|
| Molly | codex/molly-cutover-readiness-v3 | PR #11 branch codex/molly-cutover-readiness-v2 at f2b1fb1dd44a108f2a732dc72fa5b61d23b9dde3 | Current SeaWorld socket adapter and PreppyDB client |
| PreppyDB | codex/preppydb-cutover-inventory-v1 | PR #2 branch arena/e486dfa1-preppydb at 8c1bc902f8e5cc898fb8dc7e68603588f2c11b4c | Admin-only server inventory API |
| SeaWorld DB | codex/seaworld-snapshot-export-v1 | main at d6589e61564c91e2e013df69a98d0544e3026032 | Embedded MVCC logical snapshot export |

Existing Molly PRs #9, #10 and #11 remain open. Molly V3 PR #13 is open as a draft on this branch, targeting the PR #11 readiness branch. PreppyDB PR #2 remains open, PR #3 remains a separate draft, and V3 inventory PR #4 is open and draft. SeaWorld snapshot PR #2 is open and draft. No changes have been merged. The SeaWorld snapshot API is a library change; it is not a running service or network endpoint.

## Implemented in this readiness candidate

### SeaWorld source capability

The embedded SeaWorld library now offers an MVCC-pinned logical snapshot API
for V3/V4 files. It returns a stable identity derived from database ID and
committed version; complete sorted logical collection inventory, including
empty collections; bounded ascending document pages; record, collection and
root SHA-256 digests; encoded record sizes; and a live epoch-drift check.
Deletes before the snapshot appear as absence; changes after the snapshot do
not alter its leased view. Tests cover inserts, deletes, collection changes,
repeatable inventory and invalid page bounds.

It intentionally does not export storage indexes or physical WAL tombstone
frames, nor persist a snapshot lease across process restart. It is not exposed
by a daemon, CLI export command, or Molly's configured SeaWorld socket
transport. The required Molly source adapter therefore remains unavailable.

### PreppyDB destination inventory

The PreppyDB candidate adds admin-only GET endpoints for a complete logical
inventory and bounded key/hash pages. The inventory is calculated from current
engine state rather than import receipts. It includes all collection metadata
and stored documents, per-collection and root SHA-256, counts and canonical
serialized sizes. Pages expose identities and hashes, never document values,
and are rejected after a write or checkpoint changes their sequence/generation.

Every u64 count, size, sequence and generation is emitted as a decimal string
for Lua 5.1 precision safety. The root is a PreppyDB-specific canonical logical
digest; it is not directly comparable with SeaWorld's binary-codec digest.
Pages do not provide a durable lease or document values and cannot alone serve
as an import source or a race-free migration snapshot.

### Molly target client and tests

The Molly client can request and validate the admin inventory and page
contracts, preserving exact decimal strings, rejecting malformed hashes,
cursors, counts and request arguments. A mock test covers identifiers above
2^53 and bad responses. The isolated Luvit integration workflow now exercises
the actual candidate server: admin access, unauthenticated refusal, full
inventory, epoch-stale page refusal, key/hash pages, and digest equality after
SIGKILL plus restart. This remains synthetic-only. PreppyDB GitHub Actions run 173 passed the candidate server and client checks on the exact pinned revision. Molly-side hosted integration is still pending its draft PR run.

The live migration policy remains unconditionally false. The workflow and
operator CLI do not open live database connections. No import adapter,
cutover, or production database write was added.

## Data and policy boundaries

PreppyDB PR #2 blocks database-owned economy primitives and dedicated
collection names such as wallet, balances, and credit_ledger. Its storage
contract and economy-readiness analysis explicitly describe one
application-owned document per guild, with wallet, bank, journal, and receipts
kept inside Molly's guild document, as the supported storage shape. This V3
work does not create a wallet/balance collection, a database-side money
operation, or change the data shape to evade a guardrail.

Because PR #2 remains a draft, Molly's migration gate keeps
preppydb_virtual_currency_policy_scope_not_approved as a fail-closed
sign-off blocker until maintainers approve this documented scope. If
maintainers intend a blanket ban on application-owned virtual-currency data,
all economy data must remain in SeaWorld and that portion stays BLOCKED; no
generic inventory or successful synthetic test is treated as authorization.

No user data, production database, running service, Raspberry Pi, or secret was
read or changed. Tests use newly created local databases and synthetic
records only.
## Snapshot, inventory and migration guarantees

| Requirement | Evidence in this candidate | Remaining limit |
|---|---|---|
| Stable SeaWorld logical view | MVCC version-pinned library snapshot and mutation tests | Not connected to Molly's transport; V1/V2 source files cannot provide this guarantee |
| Complete source inventory | API lists every logical collection, including empty collections | Molly must still validate every source collection/schema and independently map all records |
| PreppyDB target inventory | Read-lock manifest computed from persisted engine state; epoch-bound pages | Candidate endpoint is not yet released; no normalized cross-database record comparison |
| Cryptographic record checks | SHA-256 record/collection/root digests on each DB's own encoding | Source and target canonical encodings differ; an explicit semantic canonical format is missing |
| Resumable import | Existing V2 importer tests only with synthetic adapters | No actual SeaWorld export transport or released target adapter |
| Uncertain commit reconciliation | Existing V2 path refuses blind retry and requires durable receipts | Not qualified with the actual cross-database adapters |
| Unknown collections / drift | Existing Molly snapshot parser rejects unknown collection families and source epoch change; new DB APIs expose inventories/epochs | End-to-end completeness is still unproven |
| Restart verification | Candidate PreppyDB CI test compares inventory digest before and after process SIGKILL/restart | Process-abort evidence only; physical power-loss is not tested |

## Recovery and rollback states

1. Before target writes, discard the isolated candidate and keep SeaWorld as
   source of truth.
2. After import but before approval, do not switch Molly. Re-inventory and
   independently compare the source and destination before any release.
3. After a switch with no target writes, return to SeaWorld only after proving
   no write was accepted and both inventories still match.
4. After any PreppyDB write, do not point Molly back at stale SeaWorld. Stop
   writes and enter maintenance until a verified reverse reconciliation has
   been implemented and run.
5. If cutover or a commit result is ambiguous, keep both sides read-only for
   writes and reconcile using request receipts plus complete inventories. Do
   not retry arbitrary mutations.
6. After restart, re-open and verify both stores and the same committed source
   epoch. An in-process snapshot lease cannot survive the restart; recreate the
   snapshot from a verified quiescent source.

There is no qualified reverse exporter, two-way reconciliation protocol, or
automatic safe rollback after new target writes. The simulator is a guard-state
model, not a proof of data-preserving rollback.

## Durability and platform qualification

SeaWorld's repository tests cover process-crash boundaries and WAL recovery;
PreppyDB repository tests cover storage recovery, transactions, backup/restore,
and the candidate server API. Those are software/process tests on the current
Windows development host. They do not simulate loss of electrical power or
prove that hardware and filesystem caches honor flushes.

PreppyDB GitHub Actions run 173 passed an ARM64 cross-build, QEMU tests, and a smoke-artifact build at the candidate revision. This is emulated qualification, not Raspberry Pi hardware. No Raspberry Pi 4 / Debian 13 test was run; physical import, restart, restore, resource, filesystem, and power-loss qualification remain outstanding.

## Validation performed in the isolated worktrees

- SeaWorld final commit bf2b67c320c1044180f47de98496c47b545d707f:
  formatting, Clippy with warnings denied, and 128 Rust/crash tests passed
  locally. GitHub Actions run 98 (43492886808) passed Ubuntu, Windows, and MSRV
  jobs.
- PreppyDB final commit 7d209c3049dfe6850639241d3edfe07f5cedd24e:
  formatting passed; cargo test --workspace --offline --quiet reported 413
  passed, 0 failed, 3 ignored. A local Windows release server smoke test with
  synthetic data passed. GitHub Actions run 173 (43494170190) passed all
  required jobs: Linux formatting/Clippy/tests and resource benchmarks, Windows
  build/tests/HTTP smoke, real Luvit client against the local server, Docker
  persistence, Docker image builds without push, and ARM64 QEMU build/tests.
  Manual-approval stress workflows were skipped; no stress approval was
  provided.
- The prior PreppyDB run 172 failed twice in its Windows loopback smoke test
  while opening the collection request. The workflow now explicitly bypasses
  proxies for all 127.0.0.1 requests; the same local test and final hosted run
  passed.
- Molly Lua 5.1/Luvit and Python tooling was unavailable locally. Molly's
  complete hosted Lua/Python and exact-PreppyDB integration workflows will be
  reported after its draft PR is created and Actions finish.
- GitHub's ARM64 job is QEMU-based, not Raspberry Pi hardware. No production
  databases, local Docker containers, services, or Raspberry Pi were accessed.
## Remaining release blockers

- Policy sign-off for application-owned wallet fields in the canonical guild document remains open because PreppyDB PR #2 is still draft; database-owned economy features and dedicated wallet/balance collections remain prohibited, and no bypass is implemented.
- SeaWorld's new library export is not integrated into Molly's socket
  transport; writer quiescence across all possible clients is unproven.
- The target inventory endpoint must be released and its final Molly Luvit
  integration CI must pass.
- Source and target need an agreed, versioned semantic serialization for
  independent record-by-record comparison.
- Molly's actual persistence documents need an approved, complete export map;
  unknown data must remain fail-closed.
- Real adapter import, interruption/resume, unknown-commit reconciliation, and
  backup/restore rehearsal remain unqualified.
- Reverse reconciliation and a safe post-write rollback are not implemented.
- Real Raspberry Pi hardware and physical power-loss durability are untested.

Final decision: NOT READY.
