# PreppyDB Cutover Readiness V2

This change adds a fail-closed migration protocol and synthetic qualification.
It does not enable live migration, change the active backend, or authorize a
cutover. SeaWorld remains the default and authoritative source.

## Source snapshot protocol

`migration_write_gate.lua` is shared by Molly's SeaWorld GuildStore,
GlobalStore, and PreppyDBStore write paths. Each store operation takes a lease;
an uncertain commit advances the process-local epoch. Quiescing closes new
store operations and succeeds only if no operation is in flight. This is a
local Molly gate only: it cannot stop another SeaWorld client or prove that
all writers have stopped.

`migration_snapshot.lua` requires a source adapter implementing
`begin_consistent_snapshot`, `list_collections`, `list_documents`,
`validate_snapshot`, and `end_snapshot`. The provider must bind all inventory
and pages to one stable token, attest `inventory_scope="molly_persistence"`
and `inventory_complete=true`, and validate the source identity, snapshot id,
scope and write epoch after enumeration. The collection inventory must cover
every Molly-owned persistence collection and no API may silently omit a
collection. Molly's current SeaWorld socket connector
does not implement this capability. Snapshot capture against that connector
therefore returns `snapshot_capability_unavailable`; copying open database
files is not substituted for a consistent snapshot.

The bounded capture accepts only the known `molly_g_<guild>` and
`molly_global_<name>` collection families. It currently expects one state
document per collection, matching Molly's store layout. Unknown collections,
malformed pages, pagination loops, changed epochs, or malformed data fail
closed. Bounds: 10,000 collections, 10,000 pages per collection, 500 records
per page, 200,000 records and 64 MiB of encoded records.

## Manifest V2

The manifest contains schema version 2; source identity, source format,
snapshot id and write epoch; destination identity; sorted complete source
collection/key inventory; per-record encoded byte count and deterministic
checksum; area counts; record and byte totals; and a deterministic manifest
checksum. Guild records are checked so the embedded guild id matches the
source key. The current checksum is a deterministic non-cryptographic
four-residue polynomial checksum. It detects accidental drift for this
qualification path but is not an authenticity signature and must not be used
as one. A future exported operational manifest should use a reviewed
cryptographic digest and authenticated storage before production use.

## Resumable synthetic import

`resumable_migration.lua` requires the same snapshot/manifest identity and a
destination identity, target inventory capability, and a destination that
reports API `1.0.0`, engine `preppydb`, `sync_mode=always`, and
`durable_writes=true`. Current production Molly connector does not expose the
required complete inventory contract; a real run fails closed.

Batches are deterministic over manifest digest and sorted record ranges.
Each batch writes destination records plus its progress receipt in a single
multi-document transaction. Data without its matching receipt is rejected.
An unknown response returns `outcome_unknown` without retrying. A later
invocation resolves the same batch by reading and verifying its receipt and
all batch records. The importer is insert-only and rejects mismatches and
unmanifested target keys. Bounds: 25 source records per batch and 3 MiB per
serialized destination document. Synthetic tests model an atomic target
transaction, not a process crash inside the actual PreppyDB engine; native
server crash qualification remains necessary.

## Cutover and rollback simulation

`cutover_simulator.lua` models maintenance, import, verification, connector
selection and write release without changing Molly configuration or opening a
database. Before target writes, an unreleased cutover can be abandoned. Once
PreppyDB writes have occurred, rollback first forces maintenance and refuses
to re-enable stale SeaWorld state. Returning to SeaWorld requires an explicit
successful reverse reconciliation signal. No reverse exporter is implemented
or qualified here, so this is a guard-state simulation, not proof that a
lossless production rollback exists.

## Hard blockers remain

- PreppyDB PR #2's virtual-currency policy restriction remains binding; no
  naming or schema workaround is allowed.
- SeaWorld lacks the remote stable snapshot/export capability required above.
- Molly cannot presently prove a source-wide write stop across all clients.
- PreppyDB must be released with verified durable-write semantics and the
  complete inventory capability required by resumable verification.
- Live backup/restore, full manifest reconciliation and reverse migration have
  not been qualified.
- Raspberry Pi / ARM64 hardware qualification has not been run.

Consequently `molly_migration_policy.lua` remains unconditionally blocking and
the live CLI continues to perform no DB or network I/O. A future production
cutover requires separate policy approval and tested source/destination
capabilities; this phase is synthetic readiness work only.
