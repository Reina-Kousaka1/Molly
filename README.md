# Molly – Phase 0 Bootstrap

**Integration status:** the local Unix-socket transport and connector are under
validation; the systemd templates are not yet installed. The Phase-0 notes
below describe the earlier bootstrap and do not establish production readiness.
For the transport contract see `../seaworld.db/docs/local-transport.md`.

Molly is a Lua/Luvit Discord bot. The foundation contains a separately testable
Discord bootstrap, event routing, command routing, structured logs, graceful
shutdown, and a separate SeaWorld health client. It deliberately does not
contain product features.

## Runtime and dependencies

Use Luvit **2.18.1** (LuaJIT/libuv) locally in `runtime/`; do not install it
globally. Then install the application dependency into this project:

```sh
./runtime/lit install filispeen/discord.lua
```

The local installation uses Luvit 2.18.1, Lit 3.8.5, and `discord.lua` 1.2.2
(upstream tag resolves to `9cd880d10f96253d1d1cb347416ef01111479497`).
ARM64 voice/native dependencies have not been validated.

`discord.lua` was selected because it provides Gateway operation, slash
commands, interaction responses, Components, and voice support in its Luvit
implementation. Discordia remains a mature Gateway/voice option, but does not
provide current application-command or component support natively.

## Configuration

The runtime reads environment variables only. The intended production file is
`/etc/molly/molly.env` (mode `0600`, owned by `root:root`); it is never read
directly by the application and must not be committed.

Required:

- `MOLLY_DISCORD_TOKEN`

Optional:

- `MOLLY_LAVALINK_URL`, `MOLLY_LAVALINK_PASSWORD`,
  `MOLLY_LAVALINK_TIMEOUT_MS` — Molly connects to its localhost-only Lavalink
  service; the password is never logged. The timeout is validated only when a
  Lavalink URL or password is configured. Spotify credentials are isolated in
  `/etc/molly/lavalink.env`, which the runtime setup helper copies without
  displaying them.
- `SEAWORLD_HEALTH_URL`
- `SEAWORLD_TIMEOUT_MS` (default `1000`, range `100..30000`)
- `SEAWORLD_RETRY_ATTEMPTS` (default `1`, range `1..3`)
- `MOLLY_SEAWORLD_SOCKET` — absolute path of the actual local socket. Required
  for Molly's startup preflight; the systemd template supplies it.

`SEAWORLD_HEALTH_URL` must not contain credentials. Molly currently has no
defined SeaWorld authentication contract and therefore cannot safely infer one.

Copy the variable names from `.env.example`; do not put values in it.

## Local start

After placing the Luvit runtime and dependencies locally and after an operator
has populated `/etc/molly/molly.env` on the Pi:

Use the validated systemd unit after its prerequisites and dedicated identity
have been provisioned. Do not source the root-only secret file in a shell.

Logs are JSON-shaped lines on standard output. Secrets are redacted by the
logger and are not included in the status command.

## Docker image (Raspberry Pi ARM64)

Build the local image from the checked-in Luvit runtime and application files:

```sh
docker build --platform linux/arm64 -t molly:local .
```

The image runs as UID/GID `999:983`, matching the existing `molly` account on
the Pi. It contains no token, environment file, test data, SeaWorld database,
or SeaWorld service. At runtime, supply `/etc/molly/molly.env` through Docker's
`--env-file` option and bind-mount `/run/seaworld-molly/seaworld.sock` at the
same path; the container must also be able to traverse the socket's
owner-restricted runtime directory. Do not run this container at the same time
as `molly.service`, since both would log in as the same Discord bot.

## Smoke commands

When the Discord library successfully registers application commands, Molly
exposes only `/ping`, `/about`, and `/health`. These are technical commands.
SeaWorld health is obtained from the local service and negotiated API contract.

## SeaWorld boundary and health contract

The only Molly-to-SeaWorld path is:

```text
Molly -> persistence connector -> Unix socket driver -> SeaWorld local service -> Public API -> SeaWorld engine
```

Molly does not open SeaWorld storage files. The connector negotiates API major
1 and required capabilities, fails closed on transport errors, and performs no
automatic write retry. The guild store rejects overlapping work for the same
guild and queues other guilds because transactions share one socket connection.
`tests/economy_integration.lua` exercises concurrent guild operations and
`tests/seaworld_integration.lua` exercises the real service using an isolated
test database. Request IDs correlate responses and do not guarantee
deduplication or exactly-once writes. The old HTTP health client remains only
for the Phase-0 unit tests and is not wired into startup. Staff action
idempotency receipts retain the latest 1,000 requests per guild to bound the
document size.

## Lavalink v4 foundation

`ops/lavalink/` contains Molly's Lavalink v4 service, included by
`ops/molly-container.yml`. The image is pinned to v4.2.2 and its manifest
digest. Host networking lets Lavalink use the working Pi resolver, while the
server binds only to `127.0.0.1:2333`. Compose waits for its authenticated
`/version` healthcheck before starting Molly. The YouTube source and LavaSrc
Spotify resolver use the plugin releases verified on the Pi's existing
Lavalink node; ordinary text search uses YouTube, while explicit `spsearch:`
queries and Spotify URLs resolve through LavaSrc and mirror to YouTube. Artist
enrichment is disabled to avoid an extra Spotify API request that returned
HTTP 403.

Prepare the restricted Lavalink credential file without displaying its values,
then validate and start only Molly's Compose project:

```sh
python3 ops/configure_lavalink_env.py
docker compose -f ops/molly-container.yml config --quiet
docker compose -f ops/molly-container.yml up -d
```

The setup helper reads credentials from Tori's Lavalink container but does not
change Tori or print secret values. It installs `/etc/molly/lavalink.env` as
`toriaa:toriaa` mode `0600`. The Lavalink service publishes no ports and binds
only on loopback.

## Tests

The current Pi has stock Lua 5.1 but no installed Lua test framework. The
self-contained test runner avoids adding global packages and exercises config
validation, unavailable DB, timeout propagation, valid/malformed responses,
offline Discord bootstrap, event and command routing, shutdown, status output,
music/Lavalink adapter contracts, and log redaction:

```sh
lua5.1 tests/test.lua
lua5.1 tests/socket_driver_timeout.lua
```

The socket timeout test uses a mocked connection to verify that connection
establishment is included in the configured per-call timeout. Failed initial
Discord acknowledgements are logged with a sanitized result, including an HTTP
status when the REST adapter returns one.

## Known Phase-0 limitations

- Both service templates require installation and a dedicated `molly` account.
- The root-only token configuration and production services require privileged
  setup and have not yet been verified by this unprivileged session.
- ARM64 voice dependencies and real Discord login have not been validated.
