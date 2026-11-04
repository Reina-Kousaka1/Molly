# Molly V2 command registration: local fix and deployment validation

Date: 2026-11-04 (Europe/Berlin)

## Source and GitHub baseline

- The V2 source baseline is `3d115716e9a34f92458dbe61a45dc31260b778ad`.
- The read-only check of `origin/main` returned the same commit.
- The checkout at `/mnt/bots/molly-v2-prep-3d115716` was clean on `main` before
  preparation; changes are now committed on
  `fix/permissions-command-schema-migration`.
- The working deployment tree at `/mnt/bots/molly` remains without Git metadata.
- `main` remains unchanged; the feature branch is the controlled GitHub handoff.

## Local duplicate and correction

The production registration order first registered `/permissions` from
`InformationCommands.register()` as an informational command. Later,
`PermissionCommands.register()` registered `/permissions` for guild-level
permission overrides. `Router:register()` correctly rejected the second root
name. This caused the `duplicate command: permissions` startup error before
Discord login.

The informational command is now `/my-permissions`; the administrative
`/permissions` command and its allow/grant/deny/revoke/reset/view/list actions
remain intact. No command functionality was removed.

The production command registration sequence is now centralized in
`src/commands/register_all.lua`. `molly.lua` and the registration test both call
that function, preventing the test command set from silently diverging from the
production command set.

## Local files changed

- `molly.lua` — delegates command registration to the shared production helper.
- `src/commands/register_all.lua` — holds the exact production module order.
- `src/commands/information.lua` — renames the informational command to
  `/my-permissions`.
- `tests/command_registration_all.lua` — registers the full production set and
  asserts unique names and the presence of the permission/admin commands.
- `tests/discord_registration.lua` — builds all commands using the installed
  Discord library and checks serialized command and option names and limits.
- `tests/run_ci.sh` — includes the full registration test in CI.
- `src/config.lua`, `src/discord/bootstrap.lua`, and `.env.example` — add a
  default-off, explicit migration switch.
- `src/discord/safe_sync.lua` — performs one signature-guarded PATCH for the
  legacy global command when that switch is explicitly enabled.
- `tests/command_migration.lua` and `tests/test.lua` — cover migration gating,
  API request shape, metadata preservation, and fail-closed behavior.
- `docs/local-command-registration-fix-2026-11-04.md` — this handoff record.

## Validation performed

- Full `tests/run_ci.sh`: passed, including Lua syntax checks, all Lua and
  Python suites, the full 79-command registration test, stress tests, and
  credential-handling checks.
- `tests/run_luvit.sh`: passed, including Discord-library serialization and
  interaction context checks for all 79 commands.
- Isolated Docker startup validation: passed with network disabled, without a
  Discord login, and with all 79 commands built by the installed Discord
  library.
- Compose configuration: valid.
- New ARM64 image: `molly:v2-dupfix-2026-11-04`, image ID
  `sha256:f34a93cceddcd45f5ddde8679d0b59ca231d4a2d30107d7e9de3ed1f697a0629`.
  Labels identify base revision `3d115716e9a34f92458dbe61a45dc31260b778ad`
  and local patch `permissions-command-collision`.
- Rollback image `molly:rollback-v2-2026-11-04` was retained.

## Controlled production start result

Before the single start attempt, the database backup existed at
`/mnt/bots/molly-v2-backup-20261104/seaworld-molly.v4.backup`, mode `0600`; its
directory was mode `0700`. The backup hash at verification time was
`12dfb42d26ab0b68bf2e4afaf27ca4b83d4771e431936e3a79630eda02cb2ab9`.
The environment backup also existed with mode `0600`; its contents were not
read to the terminal or logged.

The validated image identity was confirmed as ARM64 and its ID matched the
image used by `molly-bot`. Only the Molly bot service was recreated. The
one-shot deployment used restart policy `no` to prevent another automatic
attempt while validation was in progress.

Observed startup results:

- Discord Gateway: `discord_ready`, connected.
- SeaWorld: health check `healthy` (`detail=ok`). No database rollback or data
  change was performed as part of this diagnosis.
- Lavalink: health reported `connected` (`detail=v4`). Lavalink was not
  restarted or reconfigured.
- Discord command synchronization: failed safely with
  `command_conflict`, command `permissions`, field `options`.
- A read-only Discord API inspection confirmed the remote `/permissions`
  command currently has no options. The local administrative `/permissions`
  command has subcommands. The synchronizer refuses this executable schema
  change rather than overwriting the existing Discord command.

The bot container was stopped immediately after the registration failure. It
is now exited, has no automatic restart policy, and has restart count zero for
this controlled attempt. There is no active `molly.service` process. The
existing SeaWorld service, Molly Lavalink, and Tori Lavalink remained running
with unchanged restart counts. No second Molly instance was started.

## GitHub handoff and remaining blocker

The duplicate fix, targeted migration, tests, and handoff notes are prepared on
the Git-backed feature branch `fix/permissions-command-schema-migration`.
The default branch `main` has not been changed.

Before another production start, the existing remote `/permissions` schema
conflict needs an approved resolution. Any schema migration or command rename
must preserve the administrative permission-management actions and account for
the old remote command. No further production start was attempted after this
conflict was found.

## Follow-up: inspected Discord schema and prepared migration

This follow-up was read-only against Discord. The application has 60 global
commands. One Molly guild was enumerated and had zero guild-scoped commands.
Molly's local source registers global commands only. The global
`/permissions` command has ID `1565628256500191287`, no options, the description
`Show selected effective permissions`, no `default_member_permissions`,
`integration_types` `[0, 1]`, and `nsfw=false`.

The local V2 command has a description and subcommand options, so the
`options` conflict is real. It is not an array-comparison false positive. The
schema audit found no other executable schema conflicts among the 60
same-named global commands. Nineteen local commands are absent remotely and
would be created individually by a later normal sync; there are no remote-only
global commands. The API's materialized integration defaults and NSFW value
are omitted by the local model and are not schema drift to overwrite.

The migration is prepared but has not run. `MOLLY_MIGRATE_PERMISSIONS_COMMAND`
defaults to `false`. If explicitly enabled for an approved migration, the sync
will first require the exact known legacy `/permissions` signature, then issue
one `PATCH /applications/{application_id}/commands/1565628256500191287` with
only the new description and options. It does not send a command ID, permission
fields, integration types, contexts, localization, or NSFW fields. It verifies
the same ID and returned schema, then checks that the existing metadata remains
unchanged. An unexpected old schema fails closed without a request.

The local `/permissions` command continues to require `MANAGE_GUILD` in Molly's
router authorization. Its `default_member_permissions` field is omitted so the
existing Discord command-level permission value remains unchanged by the
PATCH. The stable command ID is retained; no command is deleted, renamed, or
bulk-overwritten. The official Discord API documents that PATCH edits one
command by ID and omitted optional fields remain unchanged; deleting or
renaming a command would remove its command permissions. See [Discord
Application Commands](https://discord.com/developers/docs/interactions/slash-commands).

Guild command definitions were fetched for the one guild the bot reports
membership in; that collection was empty. A per-guild permission-override GET
for the global command returned 404, so no per-guild override state is claimed.
The prepared PATCH retains the existing ID and omits all permission and
integration fields to avoid disturbing that state.

Regression tests now cover: migration disabled by default; absent options to
subcommands with the exact global command ID; no POST, DELETE, or bulk overwrite
during the migration; metadata preservation; successful subsequent normal
sync; and refusal when the remote legacy signature has changed. The migration
is test-only validated and no Discord command was changed.

## Current prepared state

- Full `tests/run_ci.sh` and `tests/run_luvit.sh` passed after the migration
  implementation; isolated tests passed inside the new image with network
  disabled and no Discord login.
- Prepared image:
  `molly:v2-permissions-migration-validated-2026-11-04`, ARM64,
  `sha256:b8d52787ad30ae3eb61a07b5fa12ce02716e03f83459b8531bb34bf22a0d3c13`.
- The production environment does not set `MOLLY_MIGRATE_PERMISSIONS_COMMAND`;
  its default remains false. The bot remains stopped on the preceding image.
- The code is on GitHub branch `fix/permissions-command-schema-migration` at
  its reviewed feature-branch head. `main` remains at the approved baseline.
  No pull request was opened and no Discord migration or production start was
  performed.
