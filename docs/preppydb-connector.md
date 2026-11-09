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
- existing collections `molly_guild_state` and `molly_global_state`.

Molly does not create collections automatically. Startup checks readiness,
PreppyDB API version `1.0.0`, token role, and both collections before connecting
the Discord client. Missing or incompatible setup fails closed. The bearer
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

## Atomic state updates

Guild state uses one document per guild in the shared `molly_guild_state`
collection, with the decimal guild ID as its key. Global state uses one
document per existing global store name in `molly_global_state`. Sharing two
collections avoids creating a collection for every guild and preserves guild
isolation at the document-key boundary.

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

There is not yet a qualified end-to-end migration command, restore rehearsal,
cutover runbook, or reverse migration. After any PreppyDB writes, rollback to
SeaWorld requires stopping writes and a separately tested reconciliation; it
is not automatically lossless.
