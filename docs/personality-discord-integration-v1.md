# Personality Engine V1 — Discord and dual-model Ollama routing

The integration is opt-in. MOLLY_PERSONALITY_ENGINE_ENABLED=false remains
the default. When enabled, it handles only direct mentions in guild messages;
commands, economy, moderation and persistence remain outside the model route.

## Verified Ollama model/API compatibility

Checked against the official Ollama library and API documentation on
2026-11-13:

- [qwen2.5:3b](https://ollama.com/library/qwen2.5:3b) accepts text input.
- [qwen3.5:2b](https://ollama.com/library/qwen3.5:2b) accepts text and image
  input and exposes the Qwen3.5 thinking capability.
- The official [/api/chat documentation](https://github.com/ollama/ollama/blob/main/docs/api.md)
  defines message images, the optional think field, keep_alive, and separate
  response fields. The adapter reads message.content only; it never forwards
  message.thinking, and removes <think>...</think> markup before returning.
- /api/show is queried before explicit Thinking use. An unknown or unavailable
  capability is treated as unsupported. /api/ps supplies best-effort
  size_vram samples while generation is active.

No live Ollama server was contacted and no model was pulled during this change.
The model names and API shapes are verified from official sources; installation,
hardware fit, output quality and latency on the target laptop still require a
controlled local test.

## Routing

- Ordinary direct mentions and text-only questions use qwen2.5:3b.
- A single validated image attachment routes to qwen3.5:2b.
- A message beginning with deep: explicitly selects qwen3.5:2b for a
  complex text question. Molly removes that routing marker before sending the
  prompt to Ollama.
- think: selects the vision model and requests Thinking only when
  MOLLY_OLLAMA_THINKING_ENABLED=true and /api/show confirms a supported
  setting. Otherwise the marker is ordinary text routed to the default model.
- If the selected model is missing, a text-only request may fall back to the
  other configured model. A request with an image never falls back to the
  text-only model. Timeouts and other failures are not automatically retried.
- A confirmed Thinking-capable vision model receives think=false by default;
  a think: request passes only the capability value reported by the model.
- One model generation at a time is enforced both by the router and Discord
  bridge. keep_alive=0 asks Ollama to unload the model after a request to
  reduce the chance that switching models holds both in VRAM.

## Image handling

Only one image per mention is supported initially. The bridge accepts an
HTTPS URL on the exact cdn.discordapp.com host under /attachments/, then
downloads without redirects and without cookies. The downloader enforces the
configured timeout and byte cap. Discord MIME metadata, the response MIME,
filename extension (when present), actual byte count and JPEG/PNG/WebP
signatures must agree. Image bytes are held transiently in memory and converted
to base64 only for the Ollama request; Molly does not persist them.

The downloader uses Luvit's pinned `coro-net` and `http-codec` modules plus
the optional `secure-socket` TLS module. Install `luvit/secure-socket@1.0.0`
with the runtime dependencies; if it is unavailable, image handling fails
closed while text-only mentions continue to work. The response body is read in
bounded chunks, and redirects are not followed.

This is signature and container-header validation, not a full image decoder.
Malformed files that mimic a supported header can still be rejected by Ollama.
GIF, SVG, animated formats and multiple-image messages are not supported.
Invalid images or vision failures receive a static, safe explanation; their
contents are never sent to the text model. Prompts cannot cause Ollama to fetch
arbitrary URLs or call tools.

## Limits, privacy and safeguards

- Direct user mentions only; DMs, bot authors, webhooks, command-like messages,
  malformed IDs and oversized message content are ignored.
- Per guild/user cooldown: 30 seconds. Maximum concurrent generations: 1.
- Duplicate Discord message IDs are rejected in flight and retained in a
  bounded, process-local 10-minute deduplication window (up to 4,096 IDs).
  The cache does not survive restart.
- Text and image request sizes are bounded. Ollama timeouts are configurable;
  no model request is retried after a timeout.
- Metrics include route, model, model switch count, request/model duration,
  model-load duration and best-effort peak size_vram samples. No prompt,
  image bytes, attachment URL or Discord content is logged.
- No model output can call commands, change economy, moderate users or write
  database state. The existing memory provider remains unwired.

The official library lists approximate model sizes of 1.9 GB for Qwen 2.5 3B
and 2.7 GB for Qwen 3.5 2B. Their combined weights exceed 4 GB before runtime
overhead. Serial generation and unload requests reduce overlap but do not prove
that Qwen 3.5 fits the laptop's 4 GB VRAM. If measured load times or memory
pressure are unacceptable, keep image/complex routing disabled at the operator
level or use one smaller model; do not silently route images to text-only Qwen.

## Windows Ollama over a private LAN

1. Keep Ollama on loopback unless a trusted private LAN/VPN connection is
   required. If enabling LAN access, restrict the Windows firewall rule to the
   Raspberry Pi's fixed private address. Never port-forward or expose TCP 11434
   publicly.
2. On the Pi's local, untracked environment file, set the feature flag, model
   names and MOLLY_OLLAMA_URL=http://<Windows-LAN-IP>:11434. The existing
   Ollama transport is HTTP-only; use a trusted private network or VPN.
3. MOLLY_OLLAMA_TEXT_MODEL and MOLLY_OLLAMA_VISION_MODEL default to the models
   above. MOLLY_OLLAMA_MODEL remains as a legacy text-model override only when
   MOLLY_OLLAMA_TEXT_MODEL is unset.
4. Test in a private guild with the flag enabled only for that controlled run:
   a simple text mention, a deep: question, a valid supported image, an
   unsupported attachment, a missing model and a stopped Ollama server. Confirm
   one reply per message and that normal commands still work.
5. Set the flag back to false and restart after the test. This repository
   change does not alter production configuration or deploy Molly.

## Verification status

Automated mock tests verify routing, explicit Thinking behavior, image
validation, size limits, invalid attachments, fallback rules, timeouts,
single-generation locking and duplicate-message protection. The isolated Luvit
check verifies the HTTPS module loads and the downloader rejects non-allowlisted
URLs before opening a socket.

Not verified here: a live Ollama/model download, real Discord CDN TLS and
attachment payloads, target-laptop VRAM/latency, Raspberry Pi runtime/ARM64
performance, Windows firewall rules, and Discord REST delivery. The feature
flag must stay off until these checks are done separately.
