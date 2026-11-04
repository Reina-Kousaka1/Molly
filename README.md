# Molly 🖤

[![CI](https://github.com/Reina-Kousaka1/Molly/actions/workflows/ci.yml/badge.svg)](https://github.com/Reina-Kousaka1/Molly/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Lua](https://img.shields.io/badge/Lua-5.1-2C2D72.svg?logo=lua&logoColor=white)](https://www.lua.org/)
[![Platform](https://img.shields.io/badge/Platform-Raspberry_Pi_ARM64-A22846.svg?logo=raspberrypi&logoColor=white)](https://www.raspberrypi.com/)

Molly is a Lua/Luvit Discord bot built around moderation, staff management, economy, music, and reliable server operations.

She combines a modular Discord command layer with persistent guild data through SeaWorld DB, Lavalink-powered music, structured logging, and a Raspberry Pi ARM64 deployment target.

> **Development status:** Molly is actively evolving. Features and operational contracts described here reflect the repository, but production rollout of individual subsystems should still be verified against the running deployment.

## Features

The standalone companion website is in [`website/`](website/README.md). It uses only verified Molly command/catalog data; its dashboard stays disabled until Molly has a permission-checked bot API.

### Moderation

Molly provides moderation foundations for common guild-management workflows, including moderation cases and persistent guild-scoped state. The command layer is designed around Discord interactions with centralized response handling and safe command synchronization.

### Economy

The economy layer provides persistent guild/user state and transaction-oriented operations. Economy writes are routed through Molly's persistence boundary rather than directly accessing database storage.

The implementation is designed to preserve request correlation and avoid reporting successful writes when persistence fails.

Slash and prefix economy requests use separate namespaced idempotency receipts; legacy economy receipts are read and migrated lazily. Canonical journal IDs remain `E<interaction-id>` for slash commands and `EP<message-id>` for prefixes. The ledger retains up to 5,000 economy receipts per guild and rejects expired IDs rather than replaying old actions. Its journal rotates at 1,000 rows, so transaction lookup is limited to retained history. Molly derives shorter base-36 Money IDs (`M...` for interactions and `Mp-...` for messages); `/transactions` shows them and `/transaction id:<id>` looks them up within the current server. See [economy retention](docs/v2-economy-modes.md#economy-commands) for details.

### Staff management

Molly includes a staff directory and staff-management domain alongside moderation and economy. Staff state is persisted per guild through the same storage boundary.

### Music

Molly has a Lavalink v4 music foundation with support for YouTube-backed search and Spotify resolution through LavaSrc when configured. Registered commands cover playback, track search, bounded queue controls, now-playing status, and persistent music panels. The runtime caps active sessions at 500, upcoming tracks at 50 (25 added per request), and bounds pending callbacks and panel caches; voice-handshake callbacks coalesce to the latest state and saturated Lavalink queues trigger bounded playback recovery.

`/voice` configures Join-to-Create rooms and owner controls for rooms created by Molly. Runtime tracking is capped at 500 guilds and 5,000 active voice members per guild, with 100 temporary rooms per guild and bounded pending callbacks. It verifies the trigger channel's category and fails closed on cleanup when member tracking is incomplete, callback buffers overflow, or Discord cannot confirm a deletion.

The repository contains the Lavalink client/adapter and the operational configuration used by Molly's Compose stack. Music configuration remains isolated from the core bot so deployments without a valid music configuration can fail safely rather than leaking credentials. Playback requires a reachable Lavalink v4 service; deployment-specific `discord.lua` REST and voice contracts still require rollout verification.

### Discord interaction layer

Molly uses a centralized interaction/response layer for command acknowledgements, edits, follow-ups, and embeds. Command synchronization includes safeguards intended to avoid duplicate or conflicting application-command registrations.

### Presence and personality

Molly has her own presence/personality layer rather than borrowing status text from other bots. Seasonal presentation may change independently of the underlying moderation, economy, staff, and music behavior.

Molly supports guild-only message commands through the same central router and command handlers used by slash commands. The default prefix is `.`; `.money` aliases the balance handler, and fixed `.d`/`.hb` shortcuts expose message purge and confirmed hackban. Economy commands include `.balance`, `.bank`, `.daily`, `.weekly`, `.work`, `.deposit`, `.withdraw`, `.pay`, `.transactions`, and `.leaderboard`. Informational commands include `.uptime`, `.botinfo`, `.channelinfo`, `.help`, and `.about`. Guild managers can use `/settings prefix show|set|reset` and `/settings economy show|currency-name|currency-symbol|reset`. Prefixes are persisted per guild (printable ASCII, 1–8 characters); economy currency display settings are also guild-scoped and never change stored amounts. Prefix handling requires Discord's privileged **Message Content** Gateway Intent to be enabled in the Developer Portal as well as requested by Molly; this repository change does not enable it in the Portal.

### Guild permissions and community features

The V2 foundation adds guild-isolated modular settings, a central command permission engine, welcome/goodbye messages, event logs, per-guild AFK statuses, safe self-assignable roles, and a reaction starboard. Guild overrides cannot grant developer, protected, or admin access; `MOLLY_DEVELOPER_IDS` remains authoritative. New features default off where they publish messages or change guild roles, and use bounded state. See [docs/v2-community.md](docs/v2-community.md) for community features and [docs/v2-economy-modes.md](docs/v2-economy-modes.md) for inventory, the opt-in shop, mining, fashion, virtual Sephora mode, mature-content policy and optional user preferences.

Automatic welcome/goodbye delivery and member-count tracking require the privileged `GUILD_MEMBERS` Gateway Intent. It remains opt-in (`MOLLY_GUILD_MEMBERS_INTENT=false` by default) and must also be enabled in the Discord Developer Portal. Prefix commands separately require the Message Content intent.

## Architecture

At a high level:

```text
Discord
   │
   ▼
Molly / Lua + Luvit
   ├── command & event routing
   ├── response / embed layer
   ├── moderation
   ├── staff management
   ├── economy
   ├── music ───────────────► Lavalink v4
   └── persistence connector
              │
              ▼
        Unix domain socket
              │
              ▼
      SeaWorld local service
              │
              ▼
        SeaWorld Public API
              │
              ▼
         SeaWorld engine
```

Molly does **not** open SeaWorld storage files directly. Persistence goes through the local SeaWorld service and its public API boundary.

Request IDs are used for correlation. They must not be treated as a blanket exactly-once guarantee unless the underlying operation explicitly provides that contract.

## Project structure

```text
.
├── .github/workflows/   # GitHub Actions CI
├── docs/                # Project and operational documentation
├── ops/                 # Docker/Compose and service configuration
├── src/                 # Molly source modules
├── tests/               # Self-contained Lua test suite
├── Dockerfile           # Raspberry Pi / ARM64 image
├── molly.lua            # Application entry point
├── .env.example         # Variable names only — never real secrets
└── LICENSE              # AGPL-3.0
```

## Runtime

Molly is built around **Lua 5.1 / LuaJIT and Luvit**. The deployment image targets **Linux ARM64**, matching the Raspberry Pi environment used for Molly.

The project has historically used Luvit 2.18.1 and `discord.lua` for Discord Gateway/application-command functionality.

## Configuration and secrets

Runtime configuration is supplied through environment variables. Real credentials must never be committed to this repository.

The checked-in `.env.example` contains variable names/examples only.

Core configuration includes the Discord token plus optional SeaWorld and Lavalink settings. Depending on the deployed feature set, variables can include:

- `MOLLY_DISCORD_TOKEN`
- `MOLLY_SEAWORLD_SOCKET`
- `SEAWORLD_TIMEOUT_MS`
- `SEAWORLD_RETRY_ATTEMPTS`
- `MOLLY_LAVALINK_URL`
- `MOLLY_LAVALINK_PASSWORD`
- `MOLLY_LAVALINK_TIMEOUT_MS`

Production credentials are kept outside Git and should retain restrictive filesystem permissions.

Never put Discord tokens, Spotify credentials, Lavalink passwords, database material, or production `.env` contents into commits, Docker images, test fixtures, or logs.

## SeaWorld persistence

Molly's persistence path is intentionally explicit:

```text
Molly
  → persistence connector
  → Unix socket driver
  → SeaWorld local service
  → SeaWorld Public API
  → SeaWorld engine
```

The connector negotiates the supported API contract and fails closed on transport/configuration failures. Molly should not fabricate successful persistence operations when SeaWorld is unavailable.

Integration tests that exercise the real service must use an isolated test database rather than production data.

## Lavalink

Molly's Lavalink v4 operational files live under `ops/`. The current stack is designed to keep Lavalink local to Molly's runtime environment and keep credentials outside the repository.

Before changing music infrastructure, inspect the current Compose/configuration state instead of assuming that a development configuration matches production.

## Docker / Raspberry Pi ARM64

Build the bot image with:

```sh
docker build --platform linux/arm64 -t molly:local .
```

The image must not contain production secrets or SeaWorld database files.

Molly's operational Compose configuration lives under `ops/`. Validate the active configuration before updating a running deployment:

```sh
docker compose -f ops/molly-container.yml config --quiet
```

Do not start two Molly instances with the same Discord token. In particular, a legacy/systemd instance and a Docker instance must not run simultaneously.

## Tests

See [`docs/testing.md`](docs/testing.md) for the complete classification and commands. The CI-safe Lua 5.1 suites and `tests/embeds.lua`, plus the standalone Python configuration test, run without Discord, Lavalink, or SeaWorld services. `tests/run_luvit.sh` runs the two Luvit/dependency-based suites. SeaWorld integration checks are separate and require an explicitly confirmed disposable test service; never point them at production.

## Continuous Integration

GitHub Actions runs Molly's CI for pushes and pull requests targeting `main`. It runs all plain Lua 5.1 suites, `tests/embeds.lua`, and `tests/lavalink_env_transfer.py`, then checks the complete PR/commit diff with `git diff --check`.

CI intentionally does not require Molly's production Discord token, Lavalink password, Spotify credentials, or SeaWorld access. The Luvit and SeaWorld integration suites are documented separately and are not reported as CI-verified.

A green CI run verifies the repository test contract; it does not by itself prove that a particular Raspberry Pi deployment is running the same commit or configuration.

## Reliability principles

Molly is built with a few important operational rules:

- guild state must remain isolated between servers;
- Discord interactions should be acknowledged before slow I/O can invalidate them;
- persistence failures must fail closed rather than pretending a write succeeded;
- idempotency/receipt data must remain bounded where applicable;
- secrets must not be logged;
- reconnect/startup paths must avoid duplicate command registrations or duplicate background workers;
- deployments must never accidentally run two bot instances with the same token.

## Development

Before changing Molly:

1. inspect the existing implementation and tests;
2. preserve unrelated local work;
3. add regression tests for bug fixes;
4. run the relevant test suite;
5. run `git diff --check`;
6. review the complete diff before committing;
7. never commit secrets or runtime data.

Keep feature work separated from infrastructure changes where practical. Changes to SeaWorld, Lavalink, or Raspberry Pi operations should not be made merely because a Molly feature happens to depend on them.

## Security

If you discover a security issue, avoid publishing credentials, tokens, private server data, or exploitable production details in a public issue.

Molly's repository is public. Treat every committed file as public information.

## License

Molly is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. See [`LICENSE`](LICENSE).

---

<p align="center"><strong>Molly 🖤</strong><br>Moderation, music, persistence — and a little mystery.</p>
