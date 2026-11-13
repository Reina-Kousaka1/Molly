# Molly Ollama integration — Raspberry Pi readiness V1

Checked 2026-11-13 against `integration/ollama-personality-v1` at
`1283047c533e98bf613a68b3ffefba3182590aa8` (PR #8).

## Findings

- The PR is open and Draft. Its remote head is the checked SHA above; the
  branch contains the dual-model router, Discord mention bridge, bounded image
  transport, configuration, tests and documentation.
- The PR diff is 32 files (2,870 insertions, 175 deletions) relative to its
  base `arena/b9d4658e-molly`. It changes the personality/Discord path, its
  configuration and tests, plus the shared prefix resolver needed to keep
  prefixed commands out of the mention bridge. It does not change Economy,
  Shop or PreppyDB implementation files. The PreppyDB/SeaWorld/Economy state
  inherited from the PR base is not modified by this readiness work.
- The live Pi is a Raspberry Pi 4 Model B, Debian 13.7, ARM64, kernel
  `6.18.50+rpt-rpi-v8`. The current production image is
  `molly:v1.2-boutique-showcase-fix-2026-11-07`, platform `linux/arm64`;
  it has no source-revision label, so its exact Git commit cannot be proved.
  The image does not contain the new `discord_bridge`, `model_router`, image
  transport or image-validation modules, and its `src/config.lua` and
  `molly.lua` hashes differ from this branch. The Ollama integration is not
  present in the running image.
- The current production image contains Luvit 2.18.1 / Luvi 2.15.0 and the
  needed `coro-net`, `http-codec` and `secure-socket` packages. The host does
  not have a standalone `luvit` executable. The local Ollama systemd unit is
  `disabled` and `inactive`; this integration does not require an Ollama
  server on the Pi.
- At inspection, the Pi reported about 2.0 GiB available RAM, 1.4 GiB swap in
  use and 7.6 GiB free disk. These are point-in-time values, not a load test.
  Ollama inference belongs on the private Windows host. Molly permits one
  generation at a time, bounds images to 4 MiB and request timeouts, and asks
  Ollama to unload after generation. The Pi-side HTTP/TLS and Lua allocations
  still need observation during an approved live-guild test.

## Validation evidence

| Check | Result | Scope |
| --- | --- | --- |
| `tests/run_ci.sh` | PASS, exit 0; all displayed Lua/Python suites had 0 failures | Executed on this Pi / ARM64; synthetic and mock-only |
| Luvit SeaWorld frame, Lavalink mock, Discord registration and image-transport tests | PASS; frame boundaries passed, 58 commands registered by the test | Executed in a disposable ARM64 container with `--network none`, read-only source mount and no environment file or token |
| Ollama mock E2E (text, `deep:`, image, capability, duplicate delivery, timeout, provider failure and recovery) | PASS | [GitHub Actions run 43458903004](https://github.com/Reina-Kousaka1/Molly/actions/runs/43458903004) for the exact checked commit; Ubuntu x86_64, not ARM64 |
| GitHub CI | PASS | [GitHub Actions run 43458902946](https://github.com/Reina-Kousaka1/Molly/actions/runs/43458902946) for the exact checked commit |
| Live Discord/Ollama/LAN test, real CDN attachment, model latency/quality and production activation | NOT RUN | Requires a separately provisioned test bot, Windows Ollama endpoint and explicit approval |

Docker warned that this Pi kernel does not expose the memory cgroup controller;
the disposable Luvit test therefore ran network-isolated and without access to
production mounts, but Docker could not enforce the requested memory cap. The
unit tests completed successfully. Do not treat that as a measured production
load test.

## Production activation preflight — 2026-11-13

- Exactly one `molly-bot` container is running; the legacy `molly.service` is
  loaded but inactive. Container image: `molly:v1.2-boutique-showcase-fix-2026-11-07`,
  image ID `sha256:e78871099644f8a8dbb50420f491c53602bff20104790fe4fc6a137fa557ae43`.
  The production container remained running and was not restarted or replaced.
- `/etc/molly/molly.env` exists with mode `0600`. Its values were not emitted.
  `MOLLY_PERSONALITY_ENGINE_ENABLED` is unset/disabled and
  `MOLLY_OLLAMA_URL` is not configured. No text/vision model overrides are
  configured.
- The local Ollama service is disabled/inactive and port 11434 has no local
  listener. Tailscale has no Windows peer. No existing private Windows address
  was available, so no network request, model inference or attachment request
  was made.
- The current deployed image does not contain the integration's Discord bridge
  or model router. The feature is not activated in production.

**Current activation state: BLOCKED.** The missing Windows private-LAN endpoint
prevents real Ollama API/model tests. A separate Discord test bot/server is
also still required for Discord E2E. No firewall, LAN, service, production
configuration, database or bot-process changes were made during this
preflight.

## Routing and failure behavior

- Ordinary direct mentions use `qwen2.5:3b`.
- A validated single JPEG/PNG/WebP Discord attachment or explicit `deep:` text
  request uses `qwen3.5:2b`.
- Thinking is off by default. It is requested only when separately enabled
  and `/api/show` confirms the selected model capability.
- The bridge ignores DMs, bots, webhooks, commands, duplicates, cooldown
  violations and excess concurrent requests. Image fetches are restricted to
  Discord CDN attachment URLs, bounded and non-redirecting. Failures do not
  crash Molly or retry an ambiguous generation. Image requests do not fall
  back to a text-only model.
- `MOLLY_PERSONALITY_ENGINE_ENABLED=false` is the code/config default. No
  production `.env` was read or changed. SeaWorld remains the production
  backend; the personality bridge does not write Economy, moderation or
  database state. No PreppyDB cutover is involved.

## Windows Ollama configuration for a later private test

Only after a test endpoint is ready, set the local Molly test configuration to
`MOLLY_OLLAMA_URL=http://<Windows-private-LAN-IP>:11434`, with the feature flag
enabled only in the isolated test configuration. Restrict the Windows
firewall rule to the Pi's private address and private network profile. Do not
port-forward or expose port 11434 publicly. The current client is HTTP-only;
use a trusted isolated LAN or VPN. Confirm both models are installed on the
Windows host. Model registry sizes do not prove that the vision model fits in
the laptop's 4 GiB VRAM; measure load time and peak memory there before testing
images.

## Isolated Pi test procedure

The helper `ops/test-ollama-pi-isolated.sh` requires an explicit expected SHA,
source checkout and test-worktree path. It never reads an `.env`, starts
`molly.lua`, logs into Discord, contacts Ollama/SeaWorld/Lavalink, changes a
service, or updates production. It refuses dirty or mismatched worktrees and
logs tests outside the worktree. It runs the Lua/Python suite with a clean
environment. If no standalone Luvit is installed, an already-present ARM64
runtime image can provide four Luvit unit suites in a disposable container
with `--network none`, no environment file and a read-only source mount; this
subset does not include the Python-driven HTTP mock E2E.

First fetch and verify the intended remote ref read-only, then run the helper
from a Git checkout that contains the commit:

```sh
git fetch origin integration/ollama-personality-v1
git rev-parse origin/integration/ollama-personality-v1
MOLLY_TEST_SOURCE=/path/to/molly-checkout \
MOLLY_TEST_COMMIT=1283047c533e98bf613a68b3ffefba3182590aa8 \
MOLLY_TEST_REF=refs/remotes/origin/integration/ollama-personality-v1 \
MOLLY_TEST_WORKTREE=/path/to/isolated/molly-test-1283047 \
MOLLY_TEST_RESULTS=/path/to/test-results \
sh ops/test-ollama-pi-isolated.sh
```

For the networkless Luvit subset when Luvit exists only inside an ARM64 image,
also set `MOLLY_TEST_RUNTIME_IMAGE` to a local image that contains
`/app/runtime/luvit` and test dependencies. The helper does not pull the image
or mount Compose configuration, production volumes or environment files. To
run the full Luvit suite and Python Ollama E2E directly, provide `LUVIT_BIN`,
an isolated `MOLLY_TEST_DEPS_DIR`, and `MOLLY_TEST_DISCORD_MODULE`; the Python
Ollama E2E binds only to `127.0.0.1` and uses synthetic requests.

## Deployment decision

1. **Can this branch be fetched safely? YES.** Fetching the remote ref is
   read-only to the running bot; use a separate checkout/worktree at the exact
   SHA. Do not merge or replace the production image.
2. **Can it be isolated-tested without changing production Molly? YES.** The
   Pi Lua/Python and networkless Luvit checks passed, and exact-commit mock E2E
   and CI passed. A standalone host Luvit binary and full E2E on Pi remain
   unavailable in the present setup.
3. **What blocks a production update?** PR #8 remains Draft/unmerged; the
   current production environment has no configured Windows private-LAN
   Ollama endpoint; no live Discord test bot was used; real
   attachment delivery and target-laptop vision-model VRAM/latency are
   unverified; and the production image has no auditable Git revision label.
   Before any future release, resolve those checks, preserve the false feature
   default, verify SeaWorld remains selected, back up the application
   configuration and image, and obtain separate deployment approval. Rollback
   means restoring the previous Molly image/configuration only; no database
   rollback or migration is expected.

Code present on a Pi, isolated tests passing, and production deployment
approval are separate states. This work establishes the first two only.
