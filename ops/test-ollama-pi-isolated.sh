#!/bin/sh
# Safe, repeatable test preparation for the opt-in Ollama integration.
# This script never starts Molly or sources a runtime environment file.
set -eu

fail() { printf 'BLOCKED: %s\n' "$*" >&2; exit 2; }

SOURCE=${MOLLY_TEST_SOURCE:-}
EXPECTED=${MOLLY_TEST_COMMIT:-}
EXPECTED_REF=${MOLLY_TEST_REF:-}
WORKTREE=${MOLLY_TEST_WORKTREE:-}
RESULTS=${MOLLY_TEST_RESULTS:-}

[ -n "$SOURCE" ] || fail 'set MOLLY_TEST_SOURCE to a Git checkout'
[ -n "$EXPECTED" ] || fail 'set MOLLY_TEST_COMMIT to the exact 40-character commit SHA'
[ -n "$WORKTREE" ] || fail 'set MOLLY_TEST_WORKTREE to a new isolated path'
case "$EXPECTED" in
  *[!0123456789abcdefABCDEF]*|'') fail 'MOLLY_TEST_COMMIT is not a hexadecimal SHA' ;;
esac
[ "${#EXPECTED}" -eq 40 ] || fail 'MOLLY_TEST_COMMIT must be 40 characters'

SOURCE=$(git -C "$SOURCE" rev-parse --show-toplevel 2>/dev/null) || fail 'source path is not a Git checkout'
git -C "$SOURCE" cat-file -e "$EXPECTED^{commit}" 2>/dev/null || fail 'expected commit is not present locally; fetch it explicitly first'
if [ -n "$EXPECTED_REF" ]; then
  REF_SHA=$(git -C "$SOURCE" rev-parse "$EXPECTED_REF^{commit}" 2>/dev/null) || fail 'expected ref is unavailable'
  [ "$REF_SHA" = "$EXPECTED" ] || fail 'expected ref does not point to the requested commit'
fi

case "$WORKTREE" in
  /*) ;;
  *) fail 'MOLLY_TEST_WORKTREE must be an absolute path' ;;
esac
WORKTREE=$(realpath -m "$WORKTREE") || fail 'could not resolve test worktree path'
[ "$WORKTREE" != "$SOURCE" ] || fail 'test worktree must be separate from the source checkout'
case "$WORKTREE" in
  /mnt/bots/molly|/mnt/bots/molly/*) fail 'test worktree must not be inside the production Molly directory' ;;
esac

if [ -z "$RESULTS" ]; then RESULTS="$(dirname "$WORKTREE")/molly-test-results"; fi
RESULTS=$(realpath -m "$RESULTS") || fail 'could not resolve test results path'
case "$RESULTS" in
  /mnt/bots/molly|/mnt/bots/molly/*) fail 'test results must not be written inside the production Molly directory' ;;
esac
RESULT_PARENT=$(dirname "$RESULTS")
[ -d "$RESULT_PARENT" ] || fail 'test result parent directory must already exist'
AVAILABLE_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
[ -n "$AVAILABLE_KB" ] && [ "$AVAILABLE_KB" -ge 786432 ] || fail 'less than 768 MiB memory is available; no tests were started'
FREE_KB=$(df -Pk "$RESULT_PARENT" | awk 'NR == 2 {print $4}')
[ -n "$FREE_KB" ] && [ "$FREE_KB" -ge 1048576 ] || fail 'less than 1 GiB disk space is available; no tests were started'

if [ -e "$WORKTREE" ]; then
  TOP=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null) || fail 'test path exists but is not a Git worktree; it was left untouched'
  [ "$TOP" = "$WORKTREE" ] || fail 'test worktree path resolves elsewhere; it was left untouched'
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$EXPECTED" ] || fail 'existing test worktree is on a different commit; it was left untouched'
  [ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ] || fail 'existing test worktree has local changes; it was left untouched'
else
  PARENT=$(dirname "$WORKTREE")
  mkdir -p "$PARENT"
  git -C "$SOURCE" worktree add --detach "$WORKTREE" "$EXPECTED"
fi

# Refuse local environment files rather than risk using production config.
ENV_FILE=$(find "$WORKTREE" -maxdepth 1 -type f -name '.env*' ! -name '.env.example' -print -quit)
[ -z "$ENV_FILE" ] || fail 'an untracked environment file exists in the test worktree; remove it manually before testing'

if [ -z "$RESULTS" ]; then RESULTS="$(dirname "$WORKTREE")/molly-test-results"; fi
case "$RESULTS" in
  /mnt/bots/molly|/mnt/bots/molly/*) fail 'test results must not be written inside the production Molly directory' ;;
esac
mkdir -p "$RESULTS"
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
SHORT_SHA=$(printf '%s' "$EXPECTED" | cut -c1-12)
LOG=$(mktemp "$RESULTS/ollama-pi-${SHORT_SHA}-${STAMP}-XXXXXX.log")
TEST_HOME="$RESULTS/home-${STAMP}-$$"
mkdir -m 700 "$TEST_HOME"
trap 'rmdir "$TEST_HOME" 2>/dev/null || true' EXIT HUP INT TERM

printf 'commit=%s\nplatform=%s/%s\n' "$EXPECTED" "$(uname -s)" "$(uname -m)" > "$LOG"
printf 'worktree=%s\n' "$WORKTREE" >> "$LOG"

LUA_BIN=${LUA_BIN:-lua5.1}
LUAC_BIN=${LUAC_BIN:-luac5.1}
PYTHON_BIN=${PYTHON_BIN:-python3}
command -v "$LUA_BIN" >/dev/null 2>&1 || fail "missing $LUA_BIN"
command -v "$LUAC_BIN" >/dev/null 2>&1 || fail "missing $LUAC_BIN"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "missing $PYTHON_BIN"

printf 'Running Lua/Python CI-safe suite...\n'
if (cd "$WORKTREE" && nice -n 10 timeout 600s env -i \
  PATH="$PATH" HOME="$TEST_HOME" LUA_BIN="$LUA_BIN" LUAC_BIN="$LUAC_BIN" PYTHON_BIN="$PYTHON_BIN" \
  sh tests/run_ci.sh) >> "$LOG" 2>&1; then
  printf 'Lua/Python suite: PASS\n' >> "$LOG"
else
  rc=$?
  printf 'Lua/Python suite: FAIL (%s)\n' "$rc" >> "$LOG"
  printf 'FAIL: Lua/Python suite failed (exit %s); log: %s\n' "$rc" "$LOG" >&2
  exit 1
fi

LUVIT=${LUVIT_BIN:-}
if [ -z "$LUVIT" ]; then LUVIT=$(command -v luvit 2>/dev/null || true); fi
case "$LUVIT" in
  /mnt/bots/molly|/mnt/bots/molly/*) LUVIT='' ;;
esac
DEPS=${MOLLY_TEST_DEPS_DIR:-}
DISCORD_MODULE=${MOLLY_TEST_DISCORD_MODULE:-}
RUNTIME_IMAGE=${MOLLY_TEST_RUNTIME_IMAGE:-}
case "$DEPS" in
  /mnt/bots/molly|/mnt/bots/molly/*) DEPS='' ;;
esac
case "$DISCORD_MODULE" in
  /mnt/bots/molly|/mnt/bots/molly/*) DISCORD_MODULE='' ;;
esac
if [ -n "$LUVIT" ] && [ -x "$LUVIT" ] && [ -d "$DEPS" ] \
  && [ -n "$DISCORD_MODULE" ] && [ -f "$DISCORD_MODULE" ]; then
  printf 'Running native Luvit suite with isolated test dependencies...\n'
  if (cd "$WORKTREE" && nice -n 10 timeout 600s env -i \
    PATH="$PATH" HOME="$TEST_HOME" LUVIT_BIN="$LUVIT" \
    MOLLY_TEST_DEPS_DIR="$DEPS" MOLLY_TEST_DISCORD_MODULE="$DISCORD_MODULE" \
    DISCORD_LUA_AUTO_INSTALL=0 \
    sh tests/run_luvit.sh) >> "$LOG" 2>&1; then
    printf 'Native Luvit suite: PASS\n' >> "$LOG"
  else
    rc=$?
    printf 'Native Luvit suite: FAIL (%s)\n' "$rc" >> "$LOG"
    printf 'FAIL: native Luvit suite failed (exit %s); log: %s\n' "$rc" "$LOG" >&2
    exit 1
  fi
elif [ -n "$RUNTIME_IMAGE" ]; then
  command -v docker >/dev/null 2>&1 || fail 'MOLLY_TEST_RUNTIME_IMAGE was set but Docker is unavailable'
  IMAGE_PLATFORM=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$RUNTIME_IMAGE" 2>/dev/null) \
    || fail 'runtime image is not already present locally; this helper never pulls images'
  [ "$IMAGE_PLATFORM" = 'linux/arm64' ] || fail "runtime image must be linux/arm64, got $IMAGE_PLATFORM"
  printf 'Running network-isolated ARM64 Luvit unit tests from the supplied image...\n'
  if nice -n 10 timeout 600s docker run --rm --pull never --network none \
    --read-only --cpus=1 --memory=512m --memory-swap=512m --pids-limit=96 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --mount "type=bind,src=$WORKTREE,dst=/workspace,readonly" -w /workspace \
    -e MOLLY_DISCORD_TOKEN= --entrypoint /bin/sh "$RUNTIME_IMAGE" -c '
      set -eu
      env -i PATH=/usr/bin:/bin MOLLY_TEST_DEPS_DIR=/app/deps \
        MOLLY_TEST_DISCORD_MODULE=/app/deps/discord.lua/init.lua DISCORD_LUA_AUTO_INSTALL=0 \
        /app/runtime/luvit tests/seaworld_luvit_frames.lua
      env -i PATH=/usr/bin:/bin MOLLY_TEST_DEPS_DIR=/app/deps \
        MOLLY_TEST_DISCORD_MODULE=/app/deps/discord.lua/init.lua DISCORD_LUA_AUTO_INSTALL=0 \
        /app/runtime/luvit tests/lavalink_client.lua
      env -i PATH=/usr/bin:/bin MOLLY_TEST_DEPS_DIR=/app/deps \
        MOLLY_TEST_DISCORD_MODULE=/app/deps/discord.lua/init.lua DISCORD_LUA_AUTO_INSTALL=0 \
        /app/runtime/luvit tests/discord_registration.lua
      env -i PATH=/usr/bin:/bin MOLLY_TEST_DEPS_DIR=/app/deps \
        MOLLY_TEST_DISCORD_MODULE=/app/deps/discord.lua/init.lua DISCORD_LUA_AUTO_INSTALL=0 \
        /app/runtime/luvit tests/personality_image_transport_luvit.lua
    ' >> "$LOG" 2>&1; then
    printf 'Networkless ARM64 Luvit unit subset: PASS\n' >> "$LOG"
  else
    rc=$?
    printf 'Networkless ARM64 Luvit unit subset: FAIL (%s)\n' "$rc" >> "$LOG"
    printf 'FAIL: networkless ARM64 Luvit tests failed (exit %s); log: %s\n' "$rc" "$LOG" >&2
    exit 1
  fi
  printf 'PARTIAL: local Lua/Python and ARM64 Luvit unit tests passed; Python-driven Ollama mock E2E was not run in the runtime image. Log: %s\n' "$LOG"
  exit 2
else
  printf 'Native Luvit suite: NOT RUN (standalone runtime, isolated dependencies and discord.lua module path are required)\n' >> "$LOG"
  printf 'PARTIAL: Lua/Python suite passed; provide standalone Luvit and isolated dependencies or a local ARM64 runtime image. Log: %s\n' "$LOG"
  exit 2
fi

printf 'PASS: all requested local suites passed; log: %s\n' "$LOG"
