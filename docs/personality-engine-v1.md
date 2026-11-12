# Personality Engine V1 — integration architecture

Status: **integration phase, disabled by default, inert in production.**
This document describes what exists in the repository, what does not, and what a
later, explicitly approved change must do to activate the engine. It is the
contract for reviewers of the current change and for anyone planning the
activation step.

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
- Unit tests with a **simulated Ollama server** (transport-level double) and a
  synthetic in-memory PreppyDB connector. No live Ollama, Discord, PreppyDB or
  SeaWorld service is used.

Explicitly out of scope (do not read this change as implementing them):

- Automatic replies in any production Discord channel; the engine is not bound
  to any Discord event.
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
                 │  existing deterministic engine: src/personality/*   │
                 │  (UNCHANGED — still the only engine in the loop)   │
                 └───────────────┬────────────────────────────────────┘
                                 │ nothing today; a future DEV-guild-only
                                 │ bridge would live here (see activation)
                                 ▼
┌───────────────────────────────────────────────────────────────────────┐
│ Personality Engine V1  src/personality/llm_engine.lua                 │
│  · feature flag gate (disabled by default)                            │
│  · request validation, history filtering (user/assistant only)        │
│  · prompt budget: drop oldest history first, then memory, then reject │
│  · best-effort memory recall (never fatal, never writes)              │
│  · reply sanitization, @everyone/@here defang, reply length bound     │
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
| `MOLLY_OLLAMA_URL` | `http://127.0.0.1:11434` | http(s) **origin** only: no userinfo, path, query or fragment. Keep it on loopback or a trusted private network. |
| `MOLLY_OLLAMA_MODEL` | unset | Required when the engine is enabled (e.g. `qwen2.5:7b`). Printable characters only, ≤ 100 chars, no whitespace. |
| `MOLLY_OLLAMA_TIMEOUT_MS` | `15000` | 100–120000 ms. Aborts the request; no retries. |
| `MOLLY_OLLAMA_MAX_RESPONSE_BYTES` | `262144` | 1024–4194304 (4 MiB). Applied before JSON parsing and again at the transport. |

Personality-engine configuration errors **never** stop Molly from booting —
following the same pattern as music configuration. When anything is invalid,
the engine stays off, the error is logged as
`personality_engine_config_invalid` (variable names only, never values), and
the bot starts exactly as before. When valid, `molly.lua` logs
`personality_engine_prepared` with `bound_to_discord = false`.

When enabled, `molly.lua` constructs the engine once at startup purely for
readiness diagnostics. It is not registered on any event, command, gateway
hook or timer, and no code path calls `engine:generate` at runtime.

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

## Activation plan (later, explicitly approved PRs)

1. **Local qualification**: run a disposable Ollama (`ollama serve`, small
   instruct model) on a loopback/LAN host; measure latency and memory on the
   target ARM64 hardware. Expect first-token latency to dominate; cap
   `num_predict` and context.
2. **Dev-guild bridge**: a separate, reviewable change adding a message-create
   bridge behind a second flag (e.g. `MOLLY_PERSONALITY_DEV_GUILDS`), bound
   only in a test guild, with reply rate limits and no economy/moderation
   authority. Never in production channels directly.
3. **Evaluation**: prompt-injection probes (channel spam, `@everyone` bait,
   instruction override via history), reply quality spot checks per language,
   cost/latency dashboards via existing structured logging.
4. **Memory opt-in**: only after step 1–3, per "Memory provider" above.
5. **Production flag**: last step, separate approval, rollback = flag off.

Rollback for every step: set `MOLLY_PERSONALITY_ENGINE_ENABLED=false`. No data
migrations exist to roll back.

## Known limitations and open risks

- **Unverified hardware fit.** No latency, memory or stability measurements on
  Raspberry Pi ARM64 yet; an LLM may not fit alongside Molly's current workload.
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
- **Reply surface.** When a future bridge lands, @mention defanging and length
  bounds apply, but responsibility for where replies are posted must be
  re-reviewed.

## Verification status

- Unit tests (`tests/personality_engine.lua`, run in CI's Lua 5.1 job): config
  defaults/validation, adapter request shape/timeouts/HTTP classes/malformed and
  oversized responses, engine gating/validation/history/prompt budget/
  sanitization/truncation/error passthrough, memory provider CAS/bounds/corrupt
  documents, and module-boundary scans.
- The simulated Ollama server double is transport-level; it is not a real
  Ollama and its timings are not meaningful.
- Not run: live Ollama, live Discord, live PreppyDB, Raspberry Pi, any
  container or production system. Nothing in this change establishes readiness
  for automatic replies.
