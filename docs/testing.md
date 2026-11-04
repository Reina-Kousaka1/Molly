# Test matrix

Molly's tests are split by runtime and external dependencies so a skipped test is
never mistaken for a CI pass.

## CI: plain Lua 5.1 and Python

Run the self-contained suites from the repository root:

```sh
LUA_BIN=lua5.1 LUAC_BIN=luac5.1 PYTHON_BIN=python3 tests/run_ci.sh
```

The runner parses `molly.lua` and every Lua file under `src/` and `tests/`, then
runs the repository unit suites, isolated SeaWorld-driver mocks, the default
synthetic ledger stress profile, and the Python Lavalink environment-transfer
test. The Lua and Python tests use in-memory fakes or mocked transports; they do
not connect to Discord, Lavalink, or SeaWorld.

`tests/seaworld_driver.lua` verifies the client's 1,048,576-byte request and
response frame boundary, counting the terminating newline. It tests the exact
limit and one byte over, UTF-8 byte counts, `resource_limit` propagation, and
rollback using isolated fake sessions and sockets. These tests verify Molly's
client behavior only; they do not establish SeaWorld's configured limit or
server-side transaction semantics.

`tests/stress.lua`'s default profile covers 100, 500, 1,000, 5,000, and 10,000
synthetic ledger operations. It also compares journal rotation implementations
at up to 100,000 appends. For the extended 100,000-operation ledger profile run:

```sh
MOLLY_STRESS_FULL=1 lua5.1 tests/stress.lua
```

This is an in-memory Lua benchmark. It exercises ledger receipt validation,
retention, and the bounded receipt-index cache, but excludes JSON serialization,
sockets, SeaWorld commit latency, and process restarts. The latest measured
100,000-operation run completed in 11.088 seconds (about 9,019 operations per
second; p95 0.182 ms, p99 0.320 ms, maximum 11.756 ms), ending with 100,000
accounts, 1,000 journal rows, and 1,000 receipts. This is not a SeaWorld
performance result.

## Luvit and library-dependent tests

`tests/run_luvit.sh` runs the Luvit JSON frame-boundary test, mocked Lavalink
client tests, and mocked Discord registration tests. Run it with a Luvit
runtime and required Lua modules on the runtime's normal search path:

```sh
LUVIT_BIN=./runtime/luvit tests/run_luvit.sh
```

The frame-boundary test was run against upstream Luvit's JSON encoder: an
exactly 1,048,576-byte newline-terminated request was accepted, a request one
byte larger was rejected before any socket write, and the same exact/oversized
checks were made for responses. This measures Molly's serialized synthetic
frames using that encoder. It is not a live SeaWorld test. The complete Luvit
runner was not verified because the required `discord.lua` module was not
available; Lavalink and frame tests were run separately with their dependencies.

`tests/lavalink_client.lua` mocks its HTTP and WebSocket transports; it needs
Luvit's `json` module but no live Lavalink service. `tests/discord_registration.lua`
needs Luvit and `discord.lua` on `package.path` (the expected repository-local
path is `deps/`) and uses a mocked client without logging into Discord.

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
and socket path. No live SeaWorld integration, server-side frame-limit check,
rollback-after-oversize check, or cross-process concurrency test has been run.
