# Molly V1.2 — Ollama/Discord live readiness and controlled test

The automated test `tests/personality_ollama_e2e.py` exercises a real local
HTTP socket using the pinned Luvit runtime, the Molly Ollama adapter, the
Personality Engine, and the Discord mention bridge. Its mock server listens
only on loopback and tests a successful reply, duplicate-message rejection,
header and body timeouts, HTTP 503 handling, and recovery. The first real
transport run exposed a timeout defect: closing only the underlying libuv
socket did not wake coro-net's suspended coroutine reader. Molly now uses the
closer returned by coro-net, which signals the blocked reader and releases the
bridge slot. It does not prove Windows firewall
configuration, the Pi's LAN route, real Discord REST permissions, live model
quality, or Pi performance. Keep `MOLLY_PERSONALITY_ENGINE_ENABLED=false`
until the manual test below is explicitly approved and completed.

## Windows Ollama host

1. Identify the Windows host's private LAN address and the Raspberry Pi's
   fixed private LAN address. Do not use a public IP, router port-forward, or
   internet-facing proxy.
2. Ollama serves its API on `127.0.0.1:11434` by default. If the Pi must reach
   it, configure Ollama's `OLLAMA_HOST` bind address according to the installed
   Windows version, then fully quit and restart the Ollama tray application.
   Binding to `0.0.0.0:11434` makes the service listen on all interfaces, so do
   this only with a Windows Defender Firewall inbound rule restricted to the
   Pi's fixed source IP and TCP port 11434. Do not enable a broad “any remote
   address” rule or a rule on public networks. The official Ollama FAQ
   documents the `OLLAMA_HOST` setting and restarting the Windows application:
   [Ollama FAQ — network access and Windows environment variables](https://github.com/ollama/ollama/blob/main/docs/faq.mdx).
3. From Windows, verify the local endpoint with a GET to
   `http://127.0.0.1:11434/api/version`. Confirm the chosen model is already
   available locally. Do not paste tokens or private prompts into the test.
4. From the Pi, first verify only the API version endpoint at
   `http://<Windows-private-LAN-IP>:11434/api/version`. If it is unreachable,
   stop and review the private route and narrowly scoped firewall rule; do not
   open the port publicly to troubleshoot.

## Controlled Discord test

1. Back up the Pi's current local configuration without adding it to Git.
   On the Pi's untracked `.env`, use the actual supported settings:

   ```dotenv
   MOLLY_PERSONALITY_ENGINE_ENABLED=false
   MOLLY_OLLAMA_URL=http://<Windows-private-LAN-IP>:11434
   MOLLY_OLLAMA_MODEL=<an-installed-local-model>
   MOLLY_OLLAMA_TIMEOUT_MS=15000
   MOLLY_OLLAMA_MAX_RESPONSE_BYTES=262144
   ```

2. Confirm connectivity and the selected model out of band first. Keep Molly's
   feature disabled while checking config parsing or restarting.
3. Only for an explicitly approved test window and private test guild, set
   `MOLLY_PERSONALITY_ENGINE_ENABLED=true` locally and restart Molly using the
   operator's normal controlled procedure. Do not edit production settings as
   part of this repository test.
4. Mention Molly with a harmless prompt. Verify one response in the source
   channel, then check a repeated delivery of the same message, a second
   mention by the same user inside 30 seconds, a message from another bot, a
   webhook, a DM, and a normal prefix/slash command. Verify no duplicate reply
   and that normal commands/economy behavior still works.
5. With Ollama stopped only if the operator considers that safe, verify the
   request fails without crashing Molly or blocking commands. Do not repeatedly
   restart the service to induce failures.
6. Immediately set the flag back to `false`, restart Molly, and verify that
   direct mentions no longer cause Ollama calls. Keep the local `.env` private
   and untracked.

## Stop conditions and rollback

Stop the test if the listener is reachable outside the trusted private route,
if any other client can access it, if Molly sends duplicates, if ordinary
commands regress, or if a failed request leaks prompt text into logs. Roll back
by disabling the feature flag and restoring the backed-up local settings. Do
not use a public tunnel or expose TCP 11434 to the internet.

## Remaining qualification

This repository change does not perform firewall edits, alter Pi configuration,
enable the feature flag, contact Discord, or run a real Ollama model. Real
Windows/Pi networking, Discord REST payloads and permissions, production model
latency/memory usage, and operational rollback remain manual checks.
