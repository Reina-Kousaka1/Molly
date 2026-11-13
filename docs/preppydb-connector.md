# PreppyDB persistence backend

Molly has an opt-in PreppyDB persistence path through the `/v1` HTTP API. It
reuses the existing guild/global store callback contract, so the economy,
settings, moderation, staff, blacklist, and other modules continue to use the
same application-level data model. Molly never opens PreppyDB files directly.

SeaWorld remains the default and the existing production backend. This code
does not switch a deployment, copy live data, or authorize a production
cutover. Select `MOLLY_PERSISTENCE_BACKEND=preppydb` only for an isolated test
instance after provisioning and validating the target database.

## Configuration and startup checks

The PreppyDB path requires:

- `MOLLY_PERSISTENCE_BACKEND=preppydb`;
- `MOLLY_PREPPYDB_URL` using the client's supported private `http://` transport;
- `MOLLY_PREPPYDB_TOKEN` with PreppyDB `write` or `admin` role;
- existing collections `molly_guild_state`, `molly_guild_registry` and
  `molly_global_state`.

Molly does not create collections automatically. Startup checks readiness,
PreppyDB API version `1.0.0`, engine identity, writable readiness, synchronous
durability, token role, and all three collections before connecting the Discord
client. Readiness must explicitly report `read_only=false`. It accepts durability only
when `/v1/version` reports both `sync_mode="always"` and
`durable_writes=true`; missing, unknown, or contradictory fields fail closed.
Missing or incompatible setup fails closed. The bearer
token is read only from the environment and is not logged. The current client
does not provide TLS; keep it on loopback or a trusted private network and do
not expose the token to an untrusted network.

The backend selector defaults to `seaworld`. Exactly one persistence backend is
constructed for writes; there is no dual-write and no automatic fallback to
SeaWorld after a PreppyDB error.

Normal Molly startup uses the official client's bounded Luvit HTTP transport
and an async-to-coroutine bridge. Store calls must run in Luvit's coroutine
context; the bridge suspends that coroutine until the callback returns. It
does not spin the event loop, replace the bounded response reader, or retry a
write.
The repository's `package.lua` pins Molly's external `coro-net` and `coro-http`
runtime packages. Install those declared dependencies with `lit install` from
the Molly repository root before starting the application; the native
PreppyDB CI does the same before its real-server tests. These modules are not
part of the base Luvit executable.

## Atomic state updates

Guild state uses one document per guild in the shared `molly_guild_state`
collection, with the decimal guild ID as its key. A second document in
`molly_guild_registry` marks the guild as `migrated` or `new_guild`; a new
guild's state and registry entry are inserted together in one CAS transaction.
An ordinary command never creates missing state. No registry entry means
`not_migrated`; a registered guild without its state document means
`missing_document`; malformed or mismatched records fail as `invalid_store`.
New-guild creation is available only through an explicit provisioning call.

Global state uses one document per existing global store name in
`molly_global_state`. The shared collections avoid creating a collection for
every guild and preserve guild isolation at the document-key boundary.

For a changed state, Molly reads the document version, runs the existing store
callback locally, then submits one `POST /v1/transactions` containing one
conditional `put` (`expected_version`; `0` means insert-only). The state and
the ledger receipt/journal already maintained by Molly are in that same
document, so a single guild mutation is one atomic PreppyDB transaction. A
stale version is returned as a conflict; Molly does not blindly rerun the
callback. Cross-guild operations are not a single atomic transaction because
they touch separate guild documents.

PreppyDB's HTTP transaction operation atomically validates and commits the
submitted mutations as one WAL record. The client does not retry writes. If
the response is lost after submission, the result is `outcome_unknown`; the
caller must not replay an arbitrary mutation. Economy operations use Molly's
existing durable receipt and request-watermark logic: replaying the same
request through the application reads the stored result, while a reused ID
with a different payload is rejected and expired IDs are rejected rather than
applied again. This is application-level deduplication, not a PreppyDB
idempotency-key feature.

The adapter bounds encoded state documents at 3 MiB by default, below
PreppyDB's 4 MiB document ceiling. An embedding may set a different bound in
`PreppyStore.new`, but it cannot exceed the PreppyDB ceiling. Larger state fails with `resource_limit`; Molly does not delete old
history or split state automatically to make the write fit. The one-document
per-guild model therefore has an aggregate growth limit that must be measured
before any production decision.

## Verification status and boundaries

The adapter is additive and does not alter the existing SeaWorld storage path.
It still requires isolated end-to-end tests against a disposable PreppyDB
server for multi-guild behavior, write conflicts, timeout-after-commit
recovery, restart persistence, backup/restore, and large guild states. This
repository change alone does not establish production readiness, Raspberry Pi
resource qualification, complete migration, or lossless rollback after new
PreppyDB writes.

Migration tooling and a cutover runbook must be qualified separately with
synthetic data. `src.persistence.seaworld_preppydb_migration` provides an
explicit-manifest migration primitive: dry-run is the default, application
requires `apply=true`, source values are converted from SeaWorld's JSON marker
types, and destination writes are insert-only transactions. It sorts and
validates the supplied guild/global manifest, rejects duplicate or malformed
entries, validates one source record per manifest key, and verifies each
destination record by deterministic JSON encoding. Existing identical target
records make a rerun safe; differing records fail with a conflict. A lost
write acknowledgement is reported as `outcome_unknown` and is not retried.
Previously inserted target records remain in place after a later failure, so
the same explicit manifest can be rerun and reconciled. The primitive does not
discover source collections on its own: the operator must independently
establish that the manifest lists every guild and global store. Its unit tests
use synthetic in-memory connectors only; no production data is read, copied,
changed, or migrated by this repository work.

### Durability gate

Insert-only writes are not the same as durable writes. If the destination
acknowledges a transaction before it is on disk, a migration can report
`inserted` and `verified` for records that a host crash would lose. An apply
therefore probes `/v1/version` first and treats the answer as a three-valued
gate, never a binary one:

| Probe result | Meaning | Apply behaviour |
| --- | --- | --- |
| `durable` | both `sync_mode="always"` and `durable_writes=true` | proceeds |
| `not_durable` | `sync_mode` reports `never`/`none`/`off`/`periodic`/`interval`/`batch`, or `durable_writes=false` | aborts with `not_durable` **before the first write** |
| `unverifiable` | endpoint missing, transport error, unknown, missing, or contradictory fields (`inconsistent_durability`) | apply is refused before the first write |

`Migration.durability(target)` exposes the probe directly. It is deliberately
strict: both fields must be present and agree; contradictory evidence (for
example `sync_mode="always"` together with `durable_writes=false`) is
`unverifiable`, not "probably fine", and silence is never reported as
durability. The migration primitive only gates writes, but the operator CLI
also prints a read-only durability probe in dry-run mode for visibility.

This contract means the server completed its configured sync operation before
acknowledging; it does not prove that every storage controller or device honors
flushes during sudden physical power loss.

### Verify-only cutover gate

`verify_only=true` writes nothing and requires every manifest key to already be
present in the destination and byte-identical to the converted source record.
The first missing key fails the run with `not_migrated` and reports it as
`summary.failed = { collection, key, code }`. This is the gate to run
immediately before flipping `MOLLY_PERSISTENCE_BACKEND`, because it is the only
step that can distinguish "everything was migrated" from "everything that
happened to be migrated".

### Missing records and the complete manifest

For guilds, the registry is mandatory. A missing registry returns
`not_migrated`; a registry without its state document returns
`missing_document`. New guilds are provisioned only through the explicit
onboarding operation. Global records are initialized from defaults when absent,
so the complete global manifest must be verified before cutover. Consequences:

- `verify_only` must pass for the *complete* manifest before cutover.
- The manifest must be derived from the source side (the SeaWorld collections),
  never from the destination collections; a destination listing proves only
  what has already been copied.
- An empty manifest is refused by the CLI, because it would verify nothing.

### Operator command

`ops/preppydb-migrate.lua` is the legacy manifest entry point for the primitive.
It now fails closed before connecting because the current Economy policy and
live-source qualifications do not permit a production import. Use the
operator-facing gate and synthetic-only qualification path:

```sh
luvit ops/molly-db-migrate.lua preflight
luvit ops/molly-db-migrate.lua migrate --dry-run --synthetic
luvit ops/molly-db-migrate.lua migrate --synthetic
luvit ops/molly-db-migrate.lua verify --synthetic
```

These commands are not live migration controls. `backup`, live `migrate`, live
`verify`, and `cutover` report the outstanding blockers without opening
connections. Synthetic migration uses in-memory adapters and the existing
insert-only migration primitive. Its durable-write response is a synthetic
test fixture only and is not evidence about a running server.

The underlying `src.persistence.seaworld_preppydb_migration` primitive remains
covered by in-memory and disposable-server tests for manifest validation,
durability refusal, insert-only application, verify-only behavior, interruption,
resume, and idempotency. Those tests do not authorize running the legacy live
operator entry point.

There is not yet a qualified end-to-end migration run against real SeaWorld and
PreppyDB data, a restore rehearsal, a cutover runbook, or a reverse migration.
After any PreppyDB writes, rollback to SeaWorld requires stopping writes and a
separately tested reconciliation; it is not automatically lossless.

### V3 independent inventory candidate

The Molly V3 branch adds client methods for PreppyDB's candidate
administrator-only /v1/inventory and epoch-bound document page endpoints.
Large sequence, generation, count and size values are decimal strings so Lua
5.1 preserves exact u64 values. The candidate real-server workflow verifies
the returned logical digest across a synthetic process restart. This does not
make the V2 importer live: it still requires synthetic adapters, the endpoint
is not released, inventory pages contain no document values, source export is
not connected to Molly's SeaWorld transport, and no semantic cross-database
digest/reconciliation protocol exists.
The current policy forbids database-managed economy primitives and dedicated
wallet/balance collections. PR #2's storage contract describes
application-owned wallet, journal, and receipt fields inside one guild
document as the supported shape; this inventory endpoint itself does not
grant policy approval. Because PR #2 remains draft, scope sign-off remains a
fail-closed blocker. If maintainers intend a broader ban on application-owned
currency data, no economy data may be imported.