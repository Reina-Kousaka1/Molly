#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
LUA_BIN=${LUA_BIN:-lua5.1}
LUAC_BIN=${LUAC_BIN:-luac5.1}
PYTHON_BIN=${PYTHON_BIN:-python3}

"$LUAC_BIN" -p molly.lua
find src tests -type f -name '*.lua' -exec "$LUAC_BIN" -p {} +

test_status=0
for suite in \
  tests/test.lua \
  tests/seaworld_driver.lua \
  tests/developer_lifecycle.lua \
  tests/v2.lua \
  tests/personality_engine.lua \
  tests/community.lua \
  tests/economy_v2.lua \
  tests/shop_preview.lua \
  tests/retail_catalog.lua \
  tests/observability.lua \
  tests/music_voice.lua \
  tests/moderation_v2.lua \
  tests/sprint.lua \
  tests/economy_commands.lua \
  tests/prefix_commands.lua \
  tests/embeds.lua
do
  if ! "$LUA_BIN" "$suite"; then test_status=1; fi
done
if ! "$LUA_BIN" tests/stress.lua; then test_status=1; fi
if ! "$LUA_BIN" tests/economy_simulation.lua; then test_status=1; fi
if ! "$PYTHON_BIN" tests/lavalink_env_transfer.py; then test_status=1; fi
if ! "$PYTHON_BIN" tests/retail_catalog_import.py; then test_status=1; fi
exit "$test_status"
