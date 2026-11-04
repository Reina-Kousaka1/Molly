#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

LUVIT_BIN=${LUVIT_BIN:-}
if [ -z "$LUVIT_BIN" ]; then
  if [ -x ./runtime/luvit ]; then
    LUVIT_BIN=./runtime/luvit
  else
    LUVIT_BIN=$(command -v luvit || true)
  fi
fi
if [ -z "$LUVIT_BIN" ]; then
  echo "Luvit was not found; set LUVIT_BIN or provide ./runtime/luvit" >&2
  exit 127
fi

"$LUVIT_BIN" tests/seaworld_luvit_frames.lua
"$LUVIT_BIN" tests/lavalink_client.lua
"$LUVIT_BIN" tests/discord_registration.lua
"$LUVIT_BIN" tests/discord_sync_transport.lua
env -i PATH="$PATH" LUA_PATH="${LUA_PATH-}" MOLLY_DISCORD_TOKEN=fixture \
  MOLLY_SEAWORLD_SOCKET=/fake "$LUVIT_BIN" tests/isolated_molly_start.lua
