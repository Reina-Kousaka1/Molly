# `/logs` command synchronization diagnosis

The controlled production attempt migrated `/permissions` and created `afk`,
`content`, `delete`, `fashion`, `goodbye`, and `inventory`. It then reported
`write_failed` for `/logs`; Molly was stopped with restart policy `no` and no
automatic retry. The previous worker caught HTTPError but discarded both the
HTTP status and body, and its parent logged only `write_failed`. Therefore the
historical HTTP status, Discord error code, and server message cannot be
recovered from Molly's available logs. The status could also represent a local
pre-write failure; the historical cause is unconfirmed. No live write was
repeated for diagnosis.

`/logs` is a CHAT_INPUT global command with a valid-length name and description,
`default_member_permissions` of `"32"`, and five unique subcommands: `show`,
`enable`, `disable`, `channel`, and `event`. The latter has two required
parameters and seven valid string choices. No violation of the documented
command, option, or choice limits was found. On read-only inspection there were
66 global CHAT_INPUT commands, below Discord's 100-command limit, no duplicate
type/name pairs, and zero guild-scoped commands. A read-only GET reported its
own rate bucket, which does not reveal the earlier POST bucket or response.
Permissions failure and rate limiting are possible but neither is proven.

The controlled worker now includes validated HTTP status, Discord numeric error
code, a small allowlist of non-sensitive standard messages, and bounded retry
interval in diagnostic output. Raw response bodies, headers, arbitrary error
strings, and tokens are never logged. Failed writes remain single-attempt and
terminal for the current sync. When a successful response supplies a depleted
rate-limit bucket and reset time, the next write waits until that reset; this is
not a retry. Excessive or invalid waiting fails closed.

Resume preflight checks all remote definitions and skips existing commands.
Before each create it performs another read, and skips a matching newly present
command or fails closed on a conflicting definition. A concurrent external
writer can still race between this read and Discord's POST: that endpoint is an
upsert and offers no atomic create-if-absent. A single coordinated writer is
therefore required for the remaining migration.

A read-only snapshot simulation found 13 missing commands and zero updates:
`logs`, `mine`, `mode`, `my-permissions`, `observe`, `selfroles`, `sephora`,
`settings`, `shop`, `starboard`, `transaction`, `user-settings`, `welcome`.
No production Discord writes, production database changes, or service starts
were performed during this investigation.

Validated locally with the full Lua CI suite, the full Luvit suite, the real
Molly entry point using mocked SeaWorld and Discord, and isolated network-free
container tests for transport, partial resume, malformed/error responses,
rate-limit headers, and the existing `/permissions` migration. The prepared
ARM64 image is `molly:v2-sync-diagnostics-2026-11-04` with image ID
`sha256:88933de933a34e662c1dfc8f107e5162cab5f05b6729b5abc83fcce87de37a7b`.
The old HTTP response is unavailable, so successful live `/logs` registration
and its original cause remain unverified. Any further production write or bot
start needs separate authorization.
