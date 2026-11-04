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

**Open deployment blocker:** the bot's normal sync still uses the existing
Discord client, which retries 429 responses. Its underlying coro-http can also
retry after a stale reused connection closes. A sync failure can be retried on
another gateway-ready event. Therefore the subsequent registration of missing
commands does not yet meet the operator's no-retry and stop-on-error rules.
Do not run the migration or start the bot until this separate path is fixed and
end-to-end tested. The database, live Discord state, and services were not
changed during this preparation.
