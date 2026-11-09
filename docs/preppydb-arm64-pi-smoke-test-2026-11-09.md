# PreppyDB ARM64 Raspberry Pi 4 smoke-test evidence

- Status: **isolated hardware smoke test passed; production cutover NOT approved**
- Observed: 2026-11-09 (operator-provided Termius screenshots and command output)
- Repository: `Reina-Kousaka1/Molly`, branch `feature/preppydb-persistence`
- Molly integration baseline: `63f36b337d887565b490db91062da2481d5e1378`
- Pinned PreppyDB artifact revision: `8d944d64698ce614e45eb95b54d78436d7721c66`
- Artifact: `preppydb-linux-arm64-gnu-8d944d64698ce614e45eb95b54d78436d7721c66`, workflow run `42579235784`

## Scope and environment

A real Raspberry Pi 4 (4 GiB RAM), Debian 13 trixie, Linux aarch64, was accessed through Termius. Tests used only `~/preppydb-arm64-test/` and synthetic records. The temporary HTTP server bound only to `127.0.0.1:17070`; no production Molly, SeaWorld, other bots, Docker, system services, or live databases were changed by the test commands. No Rust toolchain was required on the Pi.

These observations are based on screenshots/output provided by the operator, not an automated GitHub Actions ARM64 test or an independently captured test log. Do not label them as production validation.

## Observed results

| Test | Result | Evidence |
| --- | --- | --- |
| Artifact integrity | PASS | Downloaded archive SHA-256 matched its sidecar; both internal SHA256SUMS checks returned OK |
| Native ARM64 compatibility | PASS | `file` identified both executables as Linux aarch64 ELF; CLI `--version` and server `--help` ran successfully |
| Database initialization | PASS | `preppydb-server --data-dir ... --bootstrap-token ... --init-only` exited successfully in the isolated directory; bootstrap output was kept private |
| Loopback server startup | PASS | Server listened on `127.0.0.1:17070` only |
| Health and readiness | PASS | `/healthz` and `/readyz` returned HTTP 200; CLI `health --url ...` reported `health.status=ok`, `ready.ready=true`, `ready.checks.storage=ok`, `read_only=false` |
| Offline write/read | PASS | Created `arm64_smoke`; inserted `test-001` with `number:42`; retrieved version 1 and matching value |
| Offline integrity | PASS | `preppydb verify --data-dir ...` returned `ok:true`, `issues:[]` |
| Backup and restore | PASS | Offline backup, `backup-verify`, restore to separate `smoke-restored` directory, restored `verify` and retrieval of `test-001` all succeeded |
| Server restart persistence | PASS | Reopened original synthetic database with the server, reached readiness, stopped only the identified test process, then offline-read `test-001` with `number:42`; verification returned `ok:true`, `issues:[]` |
| Cleanup | PARTIAL | Test server was stopped and test port became free; isolated test files and backup were intentionally not reported as deleted |

The original `/health` and `/v1/health` probes returned 404; the correct endpoints for this binary are `/healthz` and `/readyz`. One initial connection refusal during server startup was transient and followed by successful readiness.

## Independent Molly integration CI evidence

GitHub Actions run [42612584130](https://github.com/Reina-Kousaka1/Molly/actions/runs/42612584130) passed at commit `63f36b337d887565b490db91062da2481d5e1378`: 189 native Molly regression tests; isolated PreppyDB connector/CAS/economy/receipts; synthetic migration dry-run, apply, interruption/resume and idempotency; process restart/recovery; backup verification and separate restore/read verification.

This CI run was on Linux CI infrastructure and is **not** evidence that the Molly/Luvit integration itself was executed on the Raspberry Pi.

## Remaining qualification gates

- Run an **isolated Molly + Luvit + PreppyDB integration smoke test on real ARM64 hardware** using synthetic data; measure resource use and stability. The present Pi test exercised PreppyDB binaries and CLI, not Molly.
- Review aggregate per-guild document growth versus the adapter's configured size bound, and test realistic load and failure cases on the target hardware.
- Verify complete source inventory and explicit migration manifest, dry-run/apply reconciliation, operational backups and restore rehearsal with a reviewed runbook.
- Design and test a rollback/reconciliation procedure for writes made after cutover; simply switching back to SeaWorld would not preserve those writes.
- Obtain explicit production approval after review of monitoring, access control, backup retention, maintenance window and operational ownership.

**Decision:** hardware smoke test = PASS; integration CI = PASS; production cutover = **BLOCKED / NOT AUTHORIZED**. SeaWorld remains the production/default backend. Do not merge, deploy, migrate production data, switch backends or modify other repositories based on this evidence alone.
