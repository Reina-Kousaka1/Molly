<p align="center">
  <img src="assets/kiddyymolly-banner.png" alt="KiddyyMolly pink Sephora-inspired banner" width="100%">
</p>
<p align="center">
  <img src="assets/KiddyyMolly.png" alt="KiddyyMolly profile picture" width="320">
</p>
<h1 align="center">🎀 KiddyyMolly 💗</h1>
<p align="center"><strong>♡ Made with love, pink dreams &amp; a little bit of Sephora ♡</strong></p>

<p align="center">
  <a href="https://github.com/Reina-Kousaka1/Molly/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/Reina-Kousaka1/Molly/ci.yml?branch=main&amp;style=for-the-badge&amp;label=CI%20Checks&amp;labelColor=FADADD&amp;color=F48FB1"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img alt="AGPL-3.0" src="https://img.shields.io/badge/License-AGPL--3.0-F8BBD0?style=for-the-badge&amp;labelColor=FCE4EC"></a>
  <a href="https://www.lua.org/"><img alt="Lua 5.1" src="https://img.shields.io/badge/Lua-5.1-F48FB1?style=for-the-badge&amp;labelColor=FADADD&amp;logo=lua&amp;logoColor=AA4774"></a>
  <a href="https://www.raspberrypi.com/"><img alt="Raspberry Pi ARM64" src="https://img.shields.io/badge/Raspberry%20Pi-ARM64-F8BBD0?style=for-the-badge&amp;labelColor=FCE4EC&amp;logo=raspberrypi&amp;logoColor=AA4774"></a>
</p>
<p align="center"><img alt="Baby pink to hot pink" src="https://img.shields.io/badge/%E2%99%A1-Baby%20Pink%20%E2%80%A2%20Hot%20Pink-F48FB1?style=flat-square&amp;labelColor=FADADD"></p>

HIIII BESTIESSS!! 😭💗 I'm KiddyyMolly, your pink-bow-wearing, Sephora-obsessed Discord girlieee!! But don't get distracted by my lip gloss: I do moderation, staff management, economy, music, and serious server operations too, okayyy?!

My little tech glam squad is Lua/Luvit, a persistence layer currently backed by SeaWorld DB, Lavalink for the playlists, structured logging for receipts, and Raspberry Pi ARM64 for my cozy little home. She's booked AND busy!! 🎀

> **Glow-up status:** I'm still evolving, bestieee! 💅 These features and contracts describe what's in my repo, but PLEASE check what is actually deployed before assuming a subsystem is live in production. Cute does not mean careless!!

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 💕 My little superpowers, bestiesss!!

### 🎀 Moderation — no drama allowed, girlieee

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

Drama in MY server?! Absolutely nottt 😭 I handle moderation cases and persistent per-guild state. My Discord interaction handlers share centralized response logic and careful command syncing, because double-registering commands is sooo not the vibe.

### 💸 Economy — earn those shopping coins!!

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

Shopping money needs receipts, girlieee! 💸 I keep guild/user economy state persistent and route transactions through my persistence layer — never by sneaking directly into storage files.

And no fake success stories, bestie: requests stay correlated, and if persistence fails, I do NOT pretend your coins were saved.

Okayyy bestie, here's the important tea ☕🎀 Slash and prefix economy requests use separate namespaced idempotency receipts; legacy economy receipts are read and migrated lazily. Canonical journal IDs remain `E<interaction-id>` for slash commands and `EP<message-id>` for prefixes. The ledger retains up to 5,000 economy receipts per guild and rejects expired IDs rather than replaying old actions. Its journal rotates at 1,000 rows, so transaction lookup is limited to retained history. Molly derives shorter base-36 Money IDs (`M...` for interactions and `Mp-...` for messages); `/transactions` shows them and `/transaction id:<id>` looks them up within the current server. See [economy retention](docs/v2-economy-modes.md#economy-commands) for details.

### 💌 Staff besties & management

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

My staff besties get their own directory and management tools 💌 Staff data stays per-guild and uses the same persistence boundary, because mixing servers' business would be a disasterrr.

### 🎧 Music — skincare playlist timeee

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

Skincare routine + playlist = perfectionnn 🎧 My music foundation uses Lavalink v4, YouTube-backed search, and Spotify resolution through LavaSrc **when configured**. Registered commands cover playback, track search, bounded queue controls, now-playing status, and persistent music panels. The runtime caps active sessions at 500, upcoming tracks at 50 (25 added per request), and bounds pending callbacks and panel caches; voice-handshake callbacks coalesce to the latest state and saturated Lavalink queues trigger bounded playback recovery.

`/voice` configures Join-to-Create rooms and owner controls for rooms created by Molly. Runtime tracking is capped at 500 guilds and 5,000 active voice members per guild, with 100 temporary rooms per guild and bounded pending callbacks. It verifies the trigger channel's category and fails closed on cleanup when member tracking is incomplete, callback buffers overflow, or Discord cannot confirm a deletion.

Okayyy bestie, here's the important tea ☕🎀 The repository contains the Lavalink client/adapter and the operational configuration used by Molly's Compose stack. Music configuration remains isolated from the core bot so deployments without a valid music configuration can fail safely rather than leaking credentials. Playback requires a reachable Lavalink v4 service; deployment-specific `discord.lua` REST and voice contracts still require rollout verification.

### 💬 Discord interactions — gotta reply to my besties

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

When a bestie talks to me, I ACKNOWLEDGE her!! 💬 My centralized interaction layer handles acknowledgements, edits, follow-ups, and embeds, with sync safeguards to avoid duplicate or conflicting application commands.

### 💅 My personality & little status updates

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

I have my OWN personality and presence, thank yewww 💅 Seasonal outfits and statuses can change without touching moderation, economy, staff, or music behavior.

Molly supports guild-only message commands through the same central router and command handlers used by slash commands. The default prefix is `.`; `.money` aliases the balance handler, and fixed `.d`/`.hb` shortcuts expose message purge and confirmed hackban. Economy commands include `.balance`, `.bank`, `.daily`, `.weekly`, `.work`, `.deposit`, `.withdraw`, `.pay`, `.transactions`, and `.leaderboard`. Informational commands include `.uptime`, `.botinfo`, `.channelinfo`, `.help`, and `.about`. Guild managers can use `/settings prefix show|set|reset` and `/settings economy show|currency-name|currency-symbol|reset`. Prefixes are persisted per guild (printable ASCII, 1–8 characters); economy currency display settings are also guild-scoped and never change stored amounts. Prefix handling requires Discord's privileged **Message Content** Gateway Intent to be enabled in the Developer Portal as well as requested by Molly; this repository change does not enable it in the Portal.

### 🛍️ Community goodies & permissions

> 🎀 *Baby-pink energy, serious bot business, bestieee!*

The V2 foundation adds guild-isolated modular settings, a central command permission engine, welcome/goodbye messages, event logs, per-guild AFK statuses, safe self-assignable roles, and a reaction starboard. Guild overrides cannot grant developer, protected, or admin access; `MOLLY_DEVELOPER_IDS` remains authoritative. New features default off where they publish messages or change guild roles, and use bounded state. See [docs/v2-community.md](docs/v2-community.md) for community features and [docs/v2-economy-modes.md](docs/v2-economy-modes.md) for inventory, the opt-in shop, mining, fashion, virtual Sephora mode, mature-content policy and optional user preferences.

Okayyy bestie, here's the important tea ☕🎀 Automatic welcome/goodbye delivery and member-count tracking require the privileged `GUILD_MEMBERS` Gateway Intent. It remains opt-in (`MOLLY_GUILD_MEMBERS_INTENT=false` by default) and must also be enabled in the Discord Developer Portal. Prefix commands separately require the Message Content intent.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🧠 How my pretty little brain works

Okayyy, here's the actual wiring under my bows (yes, it's real architecture!!):

```text
Discord
   │
   ▼
KiddyyMolly / Lua + Luvit
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

Girl, I **never** open SeaWorld storage files directly. Persistence goes through the local SeaWorld service and its public API boundary.

Okayyy bestie, here's the important tea ☕🎀 Request IDs help me match things up, but PLEASE don't call that a universal exactly-once guarantee unless the operation explicitly promises one. Receipts matterrr.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🗂️ What's in my pink little closet

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

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🖥️ Where I actually liveee

Okayyy bestie, here's the important tea ☕🎀 Under the pink hoodie, I'm built with **Lua 5.1 / LuaJIT and Luvit**. The deployment image targets **Linux ARM64**, matching the Raspberry Pi environment used for Molly.

The project has historically used Luvit 2.18.1 and `discord.lua` for Discord Gateway/application-command functionality.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🔐 My secret skincare cabinet (configuration)

My configuration lives in environment variables, bestieee. Real credentials NEVER go into Git. Not even with a cute bow on top.

My `.env.example` shows names/examples only — zero real secrets, obviouslyyy.

Here are some of my actual config keys. Spell them EXACTLY like this, girlie:

- `MOLLY_DISCORD_TOKEN`
- `MOLLY_SEAWORLD_SOCKET`
- `MOLLY_PERSISTENCE_BACKEND` (defaults to `seaworld`)
- `MOLLY_PREPPYDB_URL` and `MOLLY_PREPPYDB_TOKEN` (only when explicitly selecting PreppyDB)
- `MOLLY_PREPPYDB_TIMEOUT_MS`
- `MOLLY_PREPPYDB_MAX_RESPONSE_BYTES`
- `SEAWORLD_TIMEOUT_MS`
- `SEAWORLD_RETRY_ATTEMPTS`
- `MOLLY_LAVALINK_URL`
- `MOLLY_LAVALINK_PASSWORD`
- `MOLLY_LAVALINK_TIMEOUT_MS`

Production credentials stay outside Git with restrictive file permissions. No exceptions, babes.

NEVER put Discord tokens, Spotify credentials, Lavalink passwords, database material, or production `.env` contents in commits, images, fixtures, or logs. GIRL BE FR 😭🔒

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🌊 SeaWorld DB keeps my stuff organized

My SeaWorld persistence journey is VERY intentional, bestie:

```text
Molly
  → persistence connector
  → Unix socket driver
  → SeaWorld local service
  → SeaWorld Public API
  → SeaWorld engine
```

My connector negotiates the supported API contract and fails closed when transport or config breaks. No imaginary successful writes allowed. Molly should not fabricate successful persistence operations when SeaWorld is unavailable.

Testing with the real service? Use an isolated disposable test database. Production data is NOT your test makeup palette!!

## 🧪 Optional PreppyDB backend

Molly also contains an opt-in PreppyDB HTTP persistence path. The default remains
SeaWorld, and the selector constructs only one authoritative write backend at
a time. PreppyDB requires pre-created `molly_guild_state`,
`molly_guild_registry` and `molly_global_state` collections and a write-role token. Molly stores a whole
guild/global state document using a conditional atomic transaction; writes are
not dual-written, and a failed or uncertain PreppyDB operation never silently
falls back to SeaWorld. See [the integration contract](docs/preppydb-connector.md)
for version, size, retry, and migration limitations.

`ops/preppydb-migrate.lua` is the operator command for the explicit-manifest
migration: dry run by default, `--apply` for insert-only writes, and `--verify`
as the cutover gate that fails on the first key missing from the destination. An
apply is refused unless PreppyDB affirmatively reports synced writes. An absent
or unregistered guild is never initialized by an ordinary command.

This is integration code, not a production cutover approval. It does not
migrate deployed data or establish Raspberry Pi capacity, backup/restore
qualification, or lossless rollback after new PreppyDB writes. Keep the
production default unchanged until those separate checks are completed.

## 🌸 Personality Engine V1 (preparation — disabled)

Molly also carries a **prepared, opt-in Personality Engine V1** (integration
phase): a provider-agnostic core with an Ollama HTTP adapter for a local text
model and a PreppyDB memory provider. It is **disabled by default**
(`MOLLY_PERSONALITY_ENGINE_ENABLED=false`), **not bound to any Discord event**,
and **never auto-replies or persists conversation data**. Corrupted or missing
configuration keeps the engine off and never stops Molly. SeaWorld stays the
authoritative database for all productive functions.

See [the integration architecture](docs/personality-engine-v1.md) for module
boundaries, limits, the error model, memory-provider preparation and the
activation plan. Nothing in this state establishes production readiness for
automatic personality replies.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🎶 Lavalink, my music bestie

Okayyy bestie, here's the important tea ☕🎀 Molly's Lavalink v4 operational files live under `ops/`. The current stack is designed to keep Lavalink local to Molly's runtime environment and keep credentials outside the repository.

Okayyy bestie, here's the important tea ☕🎀 Before changing music infrastructure, inspect the current Compose/configuration state instead of assuming that a development configuration matches production.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🍓 Raspberry Pi & Docker — my little home

Wanna build my ARM64 Docker outfit? Use this exact command:

```sh
docker build --platform linux/arm64 -t molly:local .
```

That image must NEVER contain production secrets or SeaWorld database files, bestie.

My operational Compose files live in `ops/`. Check the actual active configuration before touching a running deployment:

```sh
docker compose -f ops/molly-container.yml config --quiet
```

Do NOT run two KiddyyMolly instances with the same Discord token. Two queens, one token? Disasterrr. In particular, a legacy/systemd instance and a Docker instance must not run simultaneously.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🧪 Testing — green checks or no shopping!!

Need the full testing tea? [`docs/testing.md`](docs/testing.md) has the exact classification and commands. The CI-safe Lua 5.1 suites and `tests/embeds.lua`, plus the standalone Python configuration test, run without Discord, Lavalink, or SeaWorld services. `tests/run_luvit.sh` runs the two Luvit/dependency-based suites. SeaWorld integration checks are separate and require an explicitly confirmed disposable test service; never point them at production.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 💚 CI — my automated quality check

GitHub Actions is my automated bestie, checking pushes and PRs targeting `main`. It runs all plain Lua 5.1 suites, `tests/embeds.lua`, and `tests/lavalink_env_transfer.py`, then checks the complete PR/commit diff with `git diff --check`.

CI intentionally does not require Molly's production Discord token, Lavalink password, Spotify credentials, or SeaWorld access. The Luvit and SeaWorld integration suites are documented separately and are not reported as CI-verified.

A green CI run verifies the repository test contract; it does not by itself prove that a particular Raspberry Pi deployment is running the same commit or configuration.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🛡️ My non-negotiable bestie rules

My non-negotiables, because reliability is literally self-care:

- guild state must remain isolated between servers;
- Discord interactions should be acknowledged before slow I/O can invalidate them;
- persistence failures must fail closed rather than pretending a write succeeded;
- idempotency/receipt data must remain bounded where applicable;
- secrets must not be logged;
- reconnect/startup paths must avoid duplicate command registrations or duplicate background workers;
- deployments must never accidentally run two bot instances with the same token.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🛠️ Wanna help me glow up?

Before giving me a glow-up, do these things in order, girlie:

1. inspect the existing implementation and tests;
2. preserve unrelated local work;
3. add regression tests for bug fixes;
4. run the relevant test suite;
5. run `git diff --check`;
6. review the complete diff before committing;
7. never commit secrets or runtime data.

Keep feature work separated from infrastructure changes where practical. Changes to SeaWorld, Lavalink, or Raspberry Pi operations should not be made merely because a Molly feature happens to depend on them.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 🚨 Security — GIRL, protect your tokens!!

Found a security issue?! Do NOT post credentials, tokens, private server data, or exploitable production details in a public issue. Protect the girlies!!

My repository is PUBLIC, bestie. Treat every committed file like the entire internet can read it.

<p align="center">🌸 ──────── ♡ ──────── 🌸</p>

## 💗 License — open-source princess behavior

I'm licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**, girlieee! See [`LICENSE`](LICENSE).

---

<p align="center"><strong>KiddyyMolly 🎀💗</strong><br>Moderation, music, persistence — and a little too much Sephora. XOXO, bestiesss!! 💋</p>
