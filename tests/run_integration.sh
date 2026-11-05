#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "${MOLLY_TEST_CONFIRM_DISPOSABLE:-}" != "YES" ]; then
  echo "Refusing integration run; set MOLLY_TEST_CONFIRM_DISPOSABLE=YES only for a disposable test service" >&2
  exit 64
fi
if [ -z "${MOLLY_TEST_SOCKET:-}" ]; then
  echo "MOLLY_TEST_SOCKET must point to the disposable SeaWorld test socket" >&2
  exit 64
fi
if [ "$#" -ne 2 ]; then
  echo "usage: tests/run_integration.sh {economy|seaworld} {exercise|verify|reopen|unavailable}" >&2
  exit 64
fi

suite=$1
phase=$2
case "$suite:$phase" in
  economy:exercise|economy:verify|economy:unavailable)
    test_file=tests/economy_integration.lua
    ;;
  seaworld:exercise|seaworld:reopen|seaworld:unavailable)
    test_file=tests/seaworld_integration.lua
    ;;
  *)
    echo "unsupported suite/phase: $suite $phase" >&2
    exit 64
    ;;
esac

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

MOLLY_TEST_PHASE="$phase" "$LUVIT_BIN" "$test_file"
