# Personality Engine V1 — integration architecture

Status: **direct-mention Discord integration, disabled by default.** It is not
activated in production and does not establish Raspberry Pi readiness.

Molly is Molly — KiddyyMolly, the pink, Sephora-loving Discord assistant. The
engine does not introduce, alias or roleplay any other character.

## What this change is (and is not)

In scope:

- A slim, provider-agnostic **engine** (`src/personality/llm_engine.lua`) that
  assembles a bounded prompt, calls a text provider and sanitizes the reply.
- An optional **Ollama HTTP adapter** (`src/personality/ollama.lua`) for a local
  Ollama server, with a bounded single-request Luvit transport
  (`src/personality/luvit_transport.lua`).
- A **PreppyDB memory provider** (`src/personality/memory.lua`) with a recall /
  append contract, bounded documents and optimistic CAS writes. Prepared only;
  not constructed by `molly.lua`, not called from any Discord event, and no
  PreppyDB collection is created by application code.
- A **feature flag** (`MOLLY_PERSONALITY_ENGINE_ENABLED`), default `false`.
- An opt-in Discord bridge that accepts direct Molly mentions only, filters
  bots/webhooks/commands, and limits cooldown and concurrency.
- Unit tests with a **simulated Ollama server** (transport-level double) and a
  synthetic in-memory PreppyDB connector. No live Ollama, Discord, PreppyDB or
  SeaWorld service is used.

Explicitly out of scope (do not read this change as implementing them):

- Replies to non-mention messages, command execution, or economy, moderation,
  and database actions based on model output.
- Durable conversation storage anywhere; the engine never calls
  `memory:append`.
- Image generation or outfit editing.
- Mood/emotion simulation beyond the existing deterministic personality engine.
- Migrating, copying, or dual-writing SeaWorld data. SeaWorld DB remains the
  authoritative store for all existing productive functions. PreppyDB remains
  opt-in, exactly as before this change.
- Docker, Raspberry Pi deployment, or any production action.

## Architecture

```
                 ┌────────────────────────────────────────────────────┐
                 │ Discord (gateway, commands, events)                │
                 │  src/discord/*, src/events/router.lua, molly.lua   │
                 │  direct mention → bounded Ollama bridge (flagged)   │
                 │  other eligible messages → deterministic engine     │
                 └───────────────┬────────────────────────────────────┘
                                 │ only when feature flag is enabled
                                 ▼
┌───────────────────────────────────────────────────────────────────────┐
│ Personality Engine V1  src/personality/llm_engine.lua                 │
│  · feature flag gate (disabled by default)                            │
│  · request validation, history filtering (user/assistant only)        │
│  · prompt budget: drop oldest history first, then memory, then reject │
│  · best-effort memory recall (never fatal, never writes)              │
│  · reply sanitization, mention defanging, UTF-8-safe reply bound       │
└───────┬───────────────────────────────┬───────────────────────────────┘
        ▼ provider contract             ▼ memory contract (read-only for engine)
┌───────────────────────────┐  ┌────────────────────────────────────────┐
│ Ollama adapter            │  │ PreppyDB memory provider               │
│ src/personality/ollama.lua│  │ src/personality/memory.lua             │
│  · POST /api/chat         │  │  · recall(scope, limit) / append(...)  │
│  · bounded response read  │  │  · one document per scope, ring of 20  │
│  · no retries, timeouts   │  │  · expected_version CAS, no blind retry│
│  · injected transport     │  │  · collection must pre-exist (manual)  │
└───────┬───────────────────┘  └────────────────────────────────────────┘
        ▼                              ▼
┌───────────────────────────┐  ┌────────────────────────────────────────┐
│ Local Ollama server       │  │ PreppyDB (private, opt-in backend)     │
│ loopback or trusted LAN   │  │ collection: molly_personality_memory   │
└───────────────────────────┘  └────────────────────────────────────────┘
```

Module boundaries are strict: the engine and its providers contain no Discord,
SeaWorld or store references (enforced by a unit test that scans module
`require`s). Discord code never sees Ollama or PreppyDB.

## Configuration (all optional, defaults keep Molly unchanged)

| Variable | Default | Notes |
| --- | --- | --- |
| `MOLLY_PERSONALITY_ENGINE_ENABLED` | `false` | Feature flag. Only `true`/`false` accepted. |
| `MOLLY_OLLAMA_URL` | `http://127.0.0.1:11434` | `http://` **origin** only (the built-in Luvit transport does not support TLS): no userinfo, path, query or fragment. Keep it on loopback or a trusted private network. |
| MOLLY_OLLAMA_TEXT_MODEL | qwen2.5:3b | Default text model; printable characters only, ≤ 100 chars, no whitespace. |
| MOLLY_OLLAMA_VISION_MODEL | qwen3.5:2b | Model for validated images and explicit deep: text requests. |
| MOLLY_OLLAMA_MODEL | unset | Legacy text override; used only when MOLLY_OLLAMA_TEXT_MODEL is unset. |
| MOLLY_OLLAMA_THINKING_ENABLED | false | think: is honored only when enabled and /api/show confirms model support. |
| `MOLLY_OLLAMA_TIMEOUT_MS` | `15000` | 100–120000 ms. Aborts the request; no retries. |
| `MOLLY_OLLAMA_MAX_RESPONSE_BYTES` | `262144` | 1024–4194304 (4 MiB). Applied before JSON parsing and again at the transport. |
| MOLLY_OLLAMA_MAX_IMAGE_BYTES | 4194304 | 1024–4194304 bytes; one JPEG, PNG or WebP attachment. |
| MOLLY_OLLAMA_IMAGE_TIMEOUT_MS | 8000 | 100–30000 ms; HTTPS download from the Discord CDN only. |

Personality-engine configuration errors **never** stop Molly from booting —
following the same pattern as music configuration. When anything is invalid,
the engine stays off, the error is logged as
`personality_engine_config_invalid` (variable names only, never values), and
the bot starts exactly as before. When valid, `molly.lua` logs
`personality_engine_prepared`. With the feature enabled, direct mentions use
the Ollama bridge; other eligible messages retain the deterministic responder. Ordinary text uses the text model; images and explicit deep: text use the vision model. See docs/personality-discord-integration-v1.md for routing and image validation.
Messages beginning with the guild's configured prefix are left to the shared
command router, even if they mention Molly as an argument. If prefix settings
cannot be read, the bridge fails closed for that message. The bridge limits
requests to a 30-second per-guild/user cooldown and one concurrent generation.
Provider error codes are logged without request text or raw errors. The
configured transport timeout and response bound apply, with no retries.

## Limits enforced in code

| Bound | Value | Where |
| --- | --- | --- |
| User content | 1000 bytes | engine request validation |
| History entries | 8 (oldest dropped) | engine |
| History entry | 400 bytes | engine |
| Memory entries in prompt | 6 × 240 bytes | engine |
| Total prompt budget | 4000 bytes | engine (`max_prompt_chars` option) |
| Reply | 600 bytes, `...` suffix when truncated | engine |
| Ollama messages / message / total | 16 / 4200 B / 16000 B | adapter |
| Ollama response | `max_response_bytes` (default 256 KiB) | transport + adapter |
| Image count / bytes | 1 / configured (default 4 MiB) | Discord image loader |
| Stored memory entries | 20 per scope, 300 bytes each, 1800 B per recall | memory provider |

## Error model

Engine and adapter return `nil, err` where `err` is a table
`{ code, status?, retryable }`. The engine never throws. Stable codes:

- Engine: `engine_disabled`, `provider_unavailable`, `invalid_request`,
  `content_too_large`, `provider_failed`, `provider_invalid_response`,
  `empty_reply`.
- Adapter: `serialization_unavailable`, `invalid_messages`, `request_failed`,
  `timeout`, `response_too_large`, `provider_error` (HTTP 5xx, retryable),
  `rate_limited` (429, retryable), `model_not_found` (404), `http_error`,
  `invalid_response`, `empty_response`.
- Memory provider: `invalid_scope`, `invalid_entry`, `not_found` (read as
  empty history, not an error), `invalid_store`, `conflict` (CAS),
  `unavailable`, `write_failed`.

Retry policy: **none anywhere automatically.** A caller may retry
`retryable = true` failures deliberately; the engine itself fails closed.

## Memory provider (prepared, not activated)

Document model: one document per scope in a dedicated collection
(default `molly_personality_memory`), key `memory/<guild>/<channel>/<user|shared>`,
value `{ version = 1, entries = [...] }`. The collection must be provisioned by
an operator (needs a `write` token); application code never creates it. Entries
are a 20-entry ring buffer with 300-byte contents; recall returns at most 8
entries and at most 1800 bytes of text. Writes use `expected_version` CAS; a
conflict is returned as `conflict` and never blindly replayed. The provider
does not store messages, tokens or identifiers beyond what the caller passes
in the scope.

To enable memory later (a separate, approved change):

1. Provision `molly_personality_memory` on the **disposable** PreppyDB instance
   and verify with `PreppyStore`-style CAS tests; never on production data.
2. Wire `Memory.new({ connector = … })` into the engine construction in
   `molly.lua` behind the same feature flag.
3. Decide and document retention (entry count is bounded; deletion policy is a
   product decision, not made here).
4. Decide explicitly whether the engine may call `memory:append` at all — V1
   ships with **no automatic persistence**.

## Controlled manual test plan

1. Follow `docs/personality-discord-integration-v1.md` for private Windows-to-Pi
   connectivity. Restrict Windows Firewall TCP 11434 to the Pi's fixed LAN IP;
   do not forward the port from a router or expose it publicly.
2. Enable the flag only in a controlled local configuration and private test
   guild. Test mentions, bot/webhook rejection, cooldown, Ollama offline, and
   ordinary command/economy behavior.
3. Measure latency and memory on Raspberry Pi ARM64 before considering broader
   use; this change does not activate production.
4. **Evaluation**: prompt-injection probes (channel spam, `@everyone` bait,
   instruction override via history), reply quality spot checks per language,
   cost/latency dashboards via existing structured logging.
5. Memory persistence or production activation requires separate review and
   explicit approval.

Rollback for every step: set `MOLLY_PERSONALITY_ENGINE_ENABLED=false`. No data
migrations exist to roll back.

## Known limitations and open risks

- **Unverified hardware fit.** The two model weight sizes together exceed 4 GB
  before runtime overhead. Serial execution and unload requests reduce overlap,
  but laptop VRAM and Raspberry Pi ARM64 latency/memory still require measurement.
- **Prompt injection.** Channel content is untrusted input; the persona and
  history filtering reduce but cannot eliminate this. Output needs review
  before any production binding.
- **No durable memory yet** (by design). Recall is best-effort and may silently
  degrade to no context.
- **TLS.** The built-in Luvit transport is plain HTTP (like the PreppyDB
  transport). Non-loopback Ollama behind HTTPS needs a different injected
  transport; do not expose Ollama to untrusted networks.
- **Model drift.** Replies depend on the configured model; swapping models
  changes behaviour without code changes. Pin and record the model in
  deployment notes.
- **Quality/safety review pending.** The persona is a starting point, not a
  moderated deployment.
- **No guild allowlist.** Limit initial testing to a controlled bot installation
  and private test guild.

## Verification status

- Unit tests (`tests/personality_engine.lua`, run in CI's Lua 5.1 job): config
  defaults/validation, adapter request shape/timeouts/HTTP classes/malformed and
  oversized responses, engine gating/validation/history/prompt budget/
  sanitization/truncation/error passthrough, memory provider CAS/bounds/corrupt
  documents, and module-boundary scans.
- The simulated Ollama server double is transport-level; it is not a real
  Ollama and its timings are not meaningful.
- Discord bridge tests use mock messages and a mock engine; live gateway and
  REST behavior remain unverified.
- Not run: live Ollama, live Discord, live PreppyDB, Raspberry Pi, any
  container or production system. Nothing in this change establishes readiness
  for automatic replies.
