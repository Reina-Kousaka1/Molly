#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
LUA_BIN=${LUA_BIN:-lua5.1}
LUAC_BIN=${LUAC_BIN:-luac5.1}
PYTHON_BIN=${PYTHON_BIN:-python3}

"$LUAC_BIN" -p molly.lua
find src tests -type f -name '*.lua' -exec "$LUAC_BIN" -p {} +

for suite in \
  tests/test.lua \
  tests/developer_lifecycle.lua \
  tests/v2.lua \
  tests/community.lua \
  tests/economy_v2.lua \
  tests/observability.lua \
  tests/music_voice.lua \
  tests/moderation_v2.lua \
  tests/sprint.lua \
  tests/economy_commands.lua \
  tests/prefix_commands.lua \
  tests/embeds.lua
do
  "$LUA_BIN" "$suite"
done
"$PYTHON_BIN" tests/lavalink_env_transfer.py
