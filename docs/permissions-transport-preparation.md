# Permissions migration transport preparation

The legacy global `/permissions` command must be changed only by an explicit
operator action. `tools/migrate_permissions.py --execute` performs one PATCH in
an isolated process. The process has a hard ten-second request deadline, uses
TLS with certificate verification, refuses redirects, and never retries. The
script checks the application, global scope, exact command ID and legacy
schema first. It updates only the description and options, then verifies the
command identity and preserved metadata. On a timeout, network failure,
invalid JSON, 5xx, or unconfirmed response it makes only a read-only GET and
returns a non-success result, including when the new state is observed.
Credentials come from the process environment and are not printed. The Lua
specification helper is executed without the Discord token in its environment.

Automatic migration through the bot's normal synchronization is blocked. The
migration tool defaults to disabled; invoking it without `--execute` performs
no API requests. The normal Discord library remains unchanged. Regression
coverage: `python3 tests/permissions_migration_transport.py`,
`lua5.1 tests/command_migration.lua`, `tests/run_ci.sh`, and
`LUA_PATH='./deps/?.lua;./deps/?/init.lua;;' tests/run_luvit.sh`.

Preparation image: `molly:v2-permissions-once-preparation-2026-11-04`, ARM64,
`sha256:39f8bb57f563f94e3130b9bb1891b609a9ccc6be0fd89972c7ad91f20e2c48b1`.
It has not been approved for production.

## Controlled normal command sync

The bot's normal sync preflights every command before writing. Description
updates and new commands are sent individually by `tools/discord_sync_worker.py`
through `src/discord/sync_transport.lua`. Each write starts a fresh process and
connection, performs exactly one HTTPS request without redirects or retries,
and has a 12-second total deadline. The token is sent through a private pipe,
never through arguments, logs, or the subprocess environment. A 400, 403 or
429 response fails the sync; timeouts, connection loss, 5xx, malformed data,
and unconfirmed write results are treated as unknown. No further write is
attempted after either kind of failure.

`sync_state.lua` transitions from idle to running and then success, failed, or
unknown. A repeated gateway-ready or reconnect does not initiate another sync
after a result, and it cannot start a concurrent sync while one is running.
Operator investigation is required before a new process is started after a
failed or unknown result. Existing unrelated commands are not deleted and no
bulk overwrite is used. Read-only preflight still uses the Discord library.

Validation includes the complete Lua and Luvit suites, HTTP response and
network-error tests, real isolated subprocess tests with a deadline and
overlapping ready event, and the real Molly entry point with a mocked SeaWorld
driver and Discord gateway, registering and synchronizing 79 commands.
These tests do not perform a Discord login and do not exercise the production
SeaWorld database. The local ARM64 test image is
`molly:v2-controlled-sync-2026-11-04`,
`sha256:e6662c80f1e849f8be0fe771a4249bbcd3b76238302ef786b31c8075de04ac79`.
The original migration, production Discord state, databases, running services,
and rollback images have not been changed. Live operation remains subject to
explicit approval and a fresh read-only preflight.
