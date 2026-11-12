# Personality Engine V1 — Discord mention bridge

The existing Ollama engine is connected only when
`MOLLY_PERSONALITY_ENGINE_ENABLED=true`. Its shipped default remains `false`.
Invalid engine configuration leaves Molly bootable and disables the bridge.

## Message policy and safeguards

- The bridge accepts guild messages containing a direct `<@bot-id>` or
  `<@!bot-id>` mention. It ignores DMs, bot authors, webhooks, empty content,
  malformed IDs, oversized messages, and command-like text following a mention.
- Ordinary slash/prefix command routing is unchanged. When the opt-in bridge
  handles a direct mention, the legacy deterministic responder is skipped for
  that message to avoid duplicate replies. Other eligible messages still use
  the existing responder.
- Per guild/user cooldown: 30 seconds. Maximum concurrent generations: 2.
  Duplicate message IDs are rejected while in flight and retained in a bounded
  10-minute deduplication window (up to 4,096 IDs per running process). When
  the window is full, new requests fail closed until an entry expires. The
  deduplication cache is intentionally in-memory, not durable across a process
  restart. The cooldown map also has a hard entry bound.
- The existing Ollama transport enforces the configured request timeout and
  response-byte limit. No retries occur. Generation, timeout, and Discord send
  failures are logged with generic details; they do not stop command handling.
- Model output is plain text only. It cannot invoke commands, change economy,
  moderate users, or write database state. Memory remains unused.

## Windows Ollama over a private LAN

1. On Windows, run Ollama bound to its LAN interface only if the host firewall
   can restrict access. Add an inbound TCP 11434 rule whose remote address is
   only the Raspberry Pi's fixed LAN IP. Do not configure router port-forwarding,
   a public firewall rule, or an internet-facing proxy.
2. On the Pi's local, untracked `.env`, configure the flag, model and
   `MOLLY_OLLAMA_URL=http://<Windows-LAN-IP>:11434`. Do not commit or share the
   environment file. The built-in transport is HTTP, so use only a trusted,
   private LAN or VPN; do not send sensitive content over public Wi-Fi.
3. For a manual test, use a private test guild and mention Molly with a harmless
   prompt. Confirm one response, then test a bot/webhook message, a normal
   command, a repeated mention within 30 seconds and an Ollama-offline case.
   Check that commands still work and there is no second legacy reply.
4. Stop the test by setting `MOLLY_PERSONALITY_ENGINE_ENABLED=false` and
   restarting Molly. This repository change does not alter production config
   or perform a deployment.

## Remaining qualification

Mock tests cover message filtering, cooldowns, duplicate IDs, concurrency,
provider failures and response delivery. They do not prove real Discord event
payload shapes, Ollama model quality, LAN firewall correctness, TLS, Raspberry
Pi latency/memory capacity, or live REST behavior. The flag must remain off
until a separately approved, controlled end-to-end test is completed.
