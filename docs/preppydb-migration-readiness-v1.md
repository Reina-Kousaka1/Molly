# Molly × PreppyDB migration readiness (V1)

This is an engineering and test plan. SeaWorld remains the production default
and the authoritative source. Nothing here authorizes live export, migration,
backend selection, or Pi access.

## Persistence inventory

Molly's feature modules use the `GuildStore` / `GlobalStore` callbacks. The
PreppyDB adapter preserves those application boundaries; the migration CLI is
the only separate path that reads the legacy SeaWorld collections.

| Molly area | Current SeaWorld store operation | PreppyDB representation and operation |
| --- | --- | --- |
| Economy accounts, balances, journal, receipts, receipt watermarks, inventory, shop, mining and fashion purchases | Guild store callback against `molly_g_<guild>` | One `molly_guild_state/<guild>` document; read and CAS replace with `expected_version`; balance mutation, journal, and bounded receipt are in the same document transaction |
| Moderation cases, case IDs, action receipts and modlog configuration | Guild store callback against `molly_g_<guild>` | Same guild state document and CAS transaction |
| Staff directory | Guild store callback against `molly_g_<guild>` | Same guild state document and CAS transaction |
| Guild settings (prefix/economy, starboard, self-roles, community and voice settings), AFK/community state, permissions, personality state and music panel configuration | Guild store callback against `molly_g_<guild>` | Same guild state document and CAS transaction |
| Blacklist, lifecycle markers and per-user preferences | Global store callback against `molly_global_<name>` (`blacklist`, `lifecycle`, `user-settings`) | `molly_global_state/<name>` document and CAS replace; absent global documents are initialized from declared defaults |

The storage adapters contain the direct database operations. Application
modules call the store callbacks; no additional direct database call sites
were found outside the connectors and explicit migration command. Discord,
Lavalink, and file-based runtime configuration are not SeaWorld records and are
not migrated by this manifest.

The representation is deliberately one aggregate document per guild. It gives
atomic same-guild economy updates and tenant separation at the document key,
but it also means all of a guild's state shares the adapter's 3 MiB encoded
document limit (PreppyDB's maximum is 4 MiB). Cross-guild atomic operations are
not provided by this adapter. Molly's ledger receipts are application-level,
durable because they are committed in the same guild document as the ledger
mutation; they are bounded to 1,000 retained economy requests plus fail-closed
watermarks. PreppyDB does not provide a native durable idempotency-key API.

### PreppyDB virtual-currency policy blocker

PreppyDB PR #2 explicitly says its virtual-currency restriction is not worked
around and that a design requiring wallet/balance storage remains blocked.
Molly's aggregate guild document contains account balances even though its
collection is named `molly_guild_state`. This implementation does not rename
or split those records to evade a policy. Until the PreppyDB maintainers
explicitly confirm that Molly's virtual-currency workload is permitted under
the intended policy (or change the policy), production use remains blocked.

### One-shot operator tool V1

`ops/molly-db-migrate.lua` is the operator-facing command surface. Its live
`preflight`, `backup`, `migrate`, `verify`, and `cutover` commands fail closed
before opening a socket or reading connection credentials. The current policy
blockers include the virtual-currency restriction, unqualified consistent
SeaWorld snapshots and complete manifests, an unqualified source write-stop,
live-source backup/restore qualification, unsupported lossless rollback after
new PreppyDB writes, and the unreleased PreppyDB durability revision. No
command-line confirmation flag overrides these blockers.

The synthetic-only path exercises the existing migration primitive without
network or filesystem access:

```sh
luvit ops/molly-db-migrate.lua migrate --dry-run --synthetic
luvit ops/molly-db-migrate.lua migrate --synthetic
luvit ops/molly-db-migrate.lua verify --synthetic
```

It uses fixed synthetic guild/global records and in-memory source and target
adapters. It checks dry-run non-mutation, insert-only application, full record
verification, and idempotent repeat. It is a test path, not a SeaWorld backup,
PreppyDB server restore, live export, or cutover. The CI integration suite
continues to exercise real PreppyDB backup/verify/restore using disposable
synthetic server data.

The earlier `ops/preppydb-migrate.lua` entry point is also policy-gated before
it reads credentials or opens either database. Its live modes currently refuse
for the same blockers; the in-memory and disposable-server tests call the
migration primitive directly and remain available for synthetic qualification.

## Durability and transaction contract

The adapter sends a single conditional document write per changed store
callback. New guild state and its migration/onboarding registry entry use one
multi-key transaction. A conflict is returned to the caller without a blind
callback retry. A connection loss after submission is `outcome_unknown`; the
caller must resolve the same interaction/request ID by reading its durable
receipt, not repeat an arbitrary payment.

Startup now requires `/readyz` to report `ready=true` and `read_only=false`,
`/v1/version` to identify `engine="preppydb"` with API `1.0.0`, and to report **both**
`sync_mode="always"` and `durable_writes=true`. Missing or contradictory
evidence is not treated as durable. The integration workflow pins the
PreppyDB PR #2 commit that adds those fields; until that API change is merged
and released, the current published PreppyDB API cannot qualify this startup
gate. This tests a specific immutable revision, not an unpinned branch.

## Synthetic migration scope and limits

The migration primitive accepts a caller-supplied manifest, defaults to
dry-run, validates and converts the listed records, and applies insert-only
transactions that can be rerun and reconciled. Its integration tests use
synthetic in-memory SeaWorld-shaped data and a disposable PreppyDB process.
They do not connect to a live SeaWorld DB, discover every existing guild/global
key, or prove that a source snapshot is consistent. Before any real migration,
an operator must quiesce source writes, generate and independently verify a
complete source-derived manifest, and compare every migrated record.

## Cutover and rollback procedure (future, not authorized here)

1. Announce a maintenance window and stop Molly writes/events that mutate state.
2. Confirm all source writers are quiescent; create and verify a SeaWorld backup.
3. Export from a consistent source snapshot and derive the complete manifest
   from the source, not from the target.
4. Run migration dry-run, then apply to a fresh isolated target; resume only by
   rerunning the same manifest after checking conflicts/outcomes.
5. Run verify-only and compare counts plus canonical record digests for every
   guild and global store. Stop if any source key is missing, malformed, or
   different.
6. Check PreppyDB health, API, `sync_mode=always`, `durable_writes=true`, roles,
   collections, backups, and synthetic economy/recovery tests.
7. A separately approved change may select PreppyDB as the sole writer; never
   dual-write. Reopen writes only after smoke checks and monitoring are ready.

Before PreppyDB accepts new writes, switching the configured backend back to
SeaWorld is possible only if no PreppyDB state was changed after the import.
After new PreppyDB writes, rollback to SeaWorld is **not supported as a
lossless automatic action**. Stop writes, preserve both databases, and require
a separately designed and rehearsed reverse export/reconciliation plus an
explicit operator decision. No reverse migration exists in this phase.

## Raspberry Pi 4 qualification plan

No Pi or production service was accessed for this work. A later isolated
ARM64 qualification should build on native ARM64, use disposable synthetic
data, and record the exact PreppyDB/Molly commits and configuration. Measure
idle and peak RSS, CPU, disk throughput, economy read/write p50/p95/p99,
concurrent same-guild conflicts, restart/recovery, and offline backup/restore.
Run a soak test long enough to expose receipt/document growth. Establish an
abort threshold from the Pi's actual other-service baseline and available disk
before testing; these x86 CI results are not Pi measurements and provide no Pi
RAM or latency guarantee.

## Readiness decision

The adapter and synthetic test path are present, but this work does not prove a
complete source manifest, consistent live SeaWorld snapshot, reverse
reconciliation, or Pi resource envelope. PreppyDB PR #2 is also an unmerged
dependency for the strict startup durability probe. Therefore production
cutover remains blocked pending those independent qualifications and explicit
approval.
