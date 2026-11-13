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
response frame boundary, counting the terminating newline. It tests limit minus
one, the exact limit, and one byte over, UTF-8 byte counts, preflight before
transport, `resource_limit` propagation, serialization failure, ambiguous
write/commit outcomes, and rollback using isolated fake sessions and sockets.
Connector transaction tests also cover failed/throwing commit and rollback
acknowledgements.
These tests verify Molly's client behavior only; they do not establish
SeaWorld's configured limit or server-side transaction semantics.

`tests/personality_engine.lua` covers the disabled-by-default Personality
Engine V1: configuration validation, the Ollama adapter against a simulated
transport-level Ollama server (request shape, timeouts, HTTP status classes,
malformed/empty/oversized responses), engine gating, history filtering, prompt
budgeting, reply sanitization, and the PreppyDB memory provider against a
synthetic in-memory CAS connector. `tests/personality_luvit_transport.lua`
exercises the bounded Luvit transport with stubbed `coro-net`, `http-codec`
and `uv`. No live Ollama, Discord, PreppyDB or SeaWorld service is contacted.

`tests/stress.lua`'s default profile covers 100, 500, 1,000, 5,000, and 10,000
synthetic ledger operations. It also compares journal rotation implementations
at up to 100,000 appends. For the extended 100,000-operation ledger profile run:

```sh
MOLLY_STRESS_FULL=1 lua5.1 tests/stress.lua
```

This is an in-memory Lua benchmark. It exercises ledger receipt validation,
retention, and the bounded receipt-index cache, but excludes JSON serialization,
sockets, SeaWorld commit latency, and process restarts. The latest measured
100,000-operation run completed in 20.155 seconds (about 4,962 operations per
second; mean 0.202 ms, p95 0.302 ms, p99 0.474 ms, maximum 15.374 ms), ending
with 100,000 accounts, 1,000 journal rows, and 1,000 receipts. This is not a
SeaWorld performance result.

## Luvit and library-dependent tests

`tests/run_luvit.sh` runs the Luvit JSON frame-boundary test, mocked Lavalink
client tests, mocked Discord registration tests, and a direct-mention
Ollama/Discord E2E test over a real Luvit HTTP socket to an ephemeral local
mock server. Run it with a Luvit runtime and required Lua modules on the
runtime's normal search path:

```sh
LUVIT_BIN=./runtime/luvit tests/run_luvit.sh
```

The Luvit test suite uses `luvit/json@2.8`, `luvit/coro-net@3.3.1`,
`luvit/http-codec@3.0.8`, and `filispeen/discord.lua@1.2.2`. Install them into
a temporary dependency directory. Set `MOLLY_TEST_DEPS_DIR` to that directory
for single-file modules; also set `MOLLY_TEST_DISCORD_MODULE` to the absolute
`discord.lua/init.lua` path so Luvit's custom resolver retains the package's
relative `require()` context. The versioned workflow verifies the JSON and HTTP
module versions and sets both variables. The Python harness binds only to
`127.0.0.1` on an OS-assigned port, returns deterministic Ollama chat responses,
including header/body timeouts and a provider error, and verifies request
count/order without printing prompts. The test does not start Ollama, connect to
Discord, or contact an external service. Run the standalone E2E with:

```sh
LUVIT_BIN=./runtime/luvit \
MOLLY_TEST_DEPS_DIR=/path/to/temporary/deps \
python3 tests/personality_ollama_e2e.py
```

For the full Luvit suite, additionally set `MOLLY_TEST_DISCORD_MODULE` to the
absolute package entrypoint before running `tests/run_luvit.sh`.

The dedicated `.github/workflows/personality-ollama-e2e.yml` workflow builds
the pinned Luvit version, installs the test-only HTTP/Discord modules in
temporary storage, and runs the complete Luvit test runner for updates to the
personality branch and PRs targeting `main` or `arena/b9d4658e-molly`.

The pinned local Luvit run passed the SeaWorld JSON frame-boundary test, four
Lavalink mock tests, Discord registration/permissions for 58 commands, and the
loopback Ollama E2E (five HTTP requests verified, including a duplicate
in-flight event, both timeout paths, HTTP 503, and recovery). The E2E exercised
Luvit's actual HTTP socket transport. These are local synthetic tests; they do
not validate SeaWorld server behavior or contact Discord/Ollama.

The frame-boundary test accepts request and response frames at 1,048,575 and
1,048,576 bytes and rejects 1,048,577 bytes. Oversized requests are rejected
before any socket write; UTF-8 byte counting is also checked. This measures
Molly's synthetic frames using that encoder, not a live SeaWorld service.

`tests/lavalink_client.lua` mocks its HTTP and WebSocket transports; it needs
Luvit's `json` module but no live Lavalink service. `tests/discord_registration.lua`
loads the package entrypoint from `MOLLY_TEST_DISCORD_MODULE` when supplied and
uses a mocked client without logging into Discord or calling the Discord API.

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
