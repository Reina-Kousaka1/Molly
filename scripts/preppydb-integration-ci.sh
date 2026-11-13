#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

: "${PREPPYDB_SERVER_BIN:?set PREPPYDB_SERVER_BIN}"
: "${PREPPYDB_CLI_BIN:?set PREPPYDB_CLI_BIN}"
: "${LUVIT_BIN:?set LUVIT_BIN}"

for binary in "$PREPPYDB_SERVER_BIN" "$PREPPYDB_CLI_BIN" "$LUVIT_BIN"; do
  test -x "$binary" || { echo "required executable unavailable: $binary" >&2; exit 2; }
done

TMP_BASE=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
mkdir -p "$TMP_BASE"
TEST_ROOT=$(mktemp -d "$TMP_BASE/molly-preppydb-e2e.XXXXXXXX")
ARTIFACT_DIR=${ARTIFACT_DIR:-"$TMP_BASE/molly-preppydb-artifacts.$$"}
mkdir -p "$ARTIFACT_DIR"
DATA_DIR="$TEST_ROOT/database"
RESTORE_DIR="$TEST_ROOT/restored"
BACKUP_FILE="$TEST_ROOT/preppydb-test-backup.swdbackup"
SERVER_PID=
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
BASE_URL="http://127.0.0.1:$PORT"
LISTEN_ADDR="127.0.0.1:$PORT"
SERVER_LOG="$ARTIFACT_DIR/preppydb-server.log"
INIT_OUTPUT="$TEST_ROOT/bootstrap-output"

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Keep uploaded diagnostics safe even if the server ever includes an
  # Authorization value in an error log. The token is passed over stdin so it
  # does not appear in the sanitizer process arguments.
  if [[ -n "${TOKEN:-}" ]] && [[ -f "$SERVER_LOG" ]]; then
    printf '%s' "$TOKEN" | python3 -c 'import pathlib, sys; p = pathlib.Path(sys.argv[1]); s = p.read_text(errors="replace"); secret = sys.stdin.read(); p.write_text(s.replace(secret, "[REDACTED]"))' "$SERVER_LOG"
  fi
  case "$TEST_ROOT" in
    "$TMP_BASE"/molly-preppydb-e2e.*) rm -rf -- "$TEST_ROOT" ;;
    *) echo "refusing to remove unexpected temporary path: $TEST_ROOT" >&2; return 1 ;;
  esac
}
trap cleanup EXIT INT TERM

start_server() {
  "$PREPPYDB_SERVER_BIN" --data-dir "$DATA_DIR" --listen "$LISTEN_ADDR" >>"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 80); do
    if curl --fail --silent --show-error "$BASE_URL/healthz" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$SERVER_LOG" >&2
      return 1
    fi
    sleep 0.25
  done
  cat "$SERVER_LOG" >&2
  echo "PreppyDB did not become healthy within 20 seconds" >&2
  return 1
}

echo "PreppyDB server binary: $PREPPYDB_SERVER_BIN"
echo "Luvit runtime: $($LUVIT_BIN --version 2>&1)"
"$PREPPYDB_SERVER_BIN" --data-dir "$DATA_DIR" --bootstrap-token molly-e2e --init-only >"$INIT_OUTPUT"
TOKEN=$(sed -n '2p' "$INIT_OUTPUT")
test -n "$TOKEN" || { echo "PreppyDB did not create the synthetic test token" >&2; exit 1; }
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then echo "::add-mask::$TOKEN"; fi
rm -f -- "$INIT_OUTPUT"

start_server
curl --fail --silent --show-error -X POST "$BASE_URL/v1/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"name":"molly_guild_state"}' >/dev/null
curl --fail --silent --show-error -X POST "$BASE_URL/v1/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"name":"molly_guild_registry"}' >/dev/null
curl --fail --silent --show-error -X POST "$BASE_URL/v1/collections" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"name":"molly_global_state"}' >/dev/null

export PREPPYDB_URL="$BASE_URL"
export PREPPYDB_TOKEN="$TOKEN"
MOLLY_PREPPYDB_TEST_RUN_ID="$(date +%s)$$"
if [[ ! "$MOLLY_PREPPYDB_TEST_RUN_ID" =~ ^[0-9]{1,17}$ ]]; then
  echo "could not create a valid synthetic PreppyDB test run ID" >&2
  exit 1
fi
export MOLLY_PREPPYDB_TEST_RUN_ID
GUILD_3="9${MOLLY_PREPPYDB_TEST_RUN_ID}03"
MOLLY_PREPPYDB_TEST=integration "$LUVIT_BIN" tests/preppydb_luvit_entry.lua

echo "Terminating the isolated PreppyDB server with SIGKILL after acknowledged writes."
kill -KILL "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=
start_server
MOLLY_PREPPYDB_TEST=restart "$LUVIT_BIN" tests/preppydb_luvit_entry.lua

echo "Stopping the server before offline backup/restore maintenance."
kill -TERM "$SERVER_PID"
wait "$SERVER_PID"
SERVER_PID=
"$PREPPYDB_CLI_BIN" backup --out "$BACKUP_FILE" --data-dir "$DATA_DIR"
"$PREPPYDB_CLI_BIN" backup-verify --archive "$BACKUP_FILE"
"$PREPPYDB_CLI_BIN" restore --archive "$BACKUP_FILE" --target "$RESTORE_DIR"
"$PREPPYDB_CLI_BIN" verify --data-dir "$RESTORE_DIR"
"$PREPPYDB_CLI_BIN" get --collection molly_guild_state --key "$GUILD_3" --data-dir "$RESTORE_DIR" >"$ARTIFACT_DIR/restored-guild.json"
grep -E "\"guild\"[[:space:]]*:[[:space:]]*\"${GUILD_3}\"" "$ARTIFACT_DIR/restored-guild.json" >/dev/null
echo "PreppyDB isolated backup, verify and restore: pass"
