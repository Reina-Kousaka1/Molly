# Test matrix

Molly's tests are split by runtime and external dependencies so a skipped test is
never mistaken for a CI pass.

## CI: plain Lua 5.1 and Python

Run the same self-contained suites as GitHub Actions from the repository root:

```sh
LUA_BIN=lua5.1 PYTHON_BIN=python3 tests/run_ci.sh
```

`LUA_BIN` and `PYTHON_BIN` may be overridden with local executable paths. The
runner first parses `molly.lua` and every Lua file under `src/` and `tests/`
with `luac5.1 -p` (override with `LUAC_BIN`), then includes:

- `tests/test.lua`
- `tests/developer_lifecycle.lua`
- `tests/v2.lua`
- `tests/community.lua`
- `tests/economy_v2.lua`
- `tests/observability.lua`
- `tests/music_voice.lua`
- `tests/moderation_v2.lua`
- `tests/sprint.lua`
- `tests/economy_commands.lua`
- `tests/prefix_commands.lua`
- `tests/embeds.lua`
- `tests/stress.lua` (synthetic in-memory ledger and journal-rotation benchmarks;
  no SeaWorld connection; the CI ledger profile reaches 10,000 bookings and the
  rotation microbenchmark reaches 100,000 appends)

Run the extended 100,000-operation profile explicitly with
`MOLLY_STRESS_FULL=1 lua5.1 tests/stress.lua`. This profile is intentionally not
part of the per-commit CI gate because the first full run exceeded its 30-minute
job timeout while exercising the current full receipt-validation path. Its
timeout is an incomplete benchmark, never a pass or a SeaWorld result.

The Python test `tests/lavalink_env_transfer.py` uses the standard library and
exercises the environment-configuration helper without Docker or live
credentials. These CI tests use fakes/mocks and do not connect to Discord,
Lavalink, or SeaWorld.

## Luvit and library-dependent tests

`tests/lavalink_client.lua` requires Luvit's `json` module; its HTTP and WebSocket
transports are mocked, so no live Lavalink service is needed. It was previously
left out of CI because plain Lua in the test environment did not provide
`json`.

`tests/discord_registration.lua` requires Luvit and the `discord.lua` library
available on `package.path` (the repository's expected local path is `deps/`).
It uses a mocked client and does not log in to Discord.

Run both with:

```sh
LUVIT_BIN=./runtime/luvit tests/run_luvit.sh
```

The runner uses `./runtime/luvit` when present, otherwise `luvit` on `PATH`; set
`LUVIT_BIN` to select another executable. Supply the required Lua modules in the
normal Luvit search path. This group is not part of GitHub Actions unless those
runtime dependencies are deliberately provisioned there.

## SeaWorld integration tests

`tests/economy_integration.lua` and `tests/seaworld_integration.lua` require
Luvit/`uv`, a local SeaWorld V1-compatible socket service, and a disposable test
database. They write fixed test guild/collection names and must never target
production data. The economy test has `exercise`, `verify` (after a service
restart), and `unavailable` phases. The SeaWorld test has `exercise`, `reopen`
(after restart), and `unavailable` phases.

Use the explicit runner, and opt in only after confirming that the socket points
to a disposable test service:

```sh
MOLLY_TEST_CONFIRM_DISPOSABLE=YES \
MOLLY_TEST_SOCKET=/path/to/disposable-seaworld.sock \
LUVIT_BIN=./runtime/luvit \
tests/run_integration.sh economy exercise
```

Replace `economy` with `seaworld` and select the corresponding phase as needed.
The `verify`/`reopen` phase must use the same test database after restarting the
service. `unavailable` is run while that disposable service is stopped. The
runner refuses to execute without the explicit disposable-service confirmation
and socket path. No integration test is run by CI.
