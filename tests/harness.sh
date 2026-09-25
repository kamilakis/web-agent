#!/usr/bin/env bash
# Shared plumbing for the web-agent test suite.
#
# Every test runs a THROWAWAY daemon: its own state dir, its own port, its own
# fake pi on PATH, and a loopback bind. The live agent on :8383 is never
# touched — not its state, not its session, not its FIFO.
#
#     source tests/harness.sh
#     harness_init /tmp/wa-tests/foo 8399
#     reset_state && start_daemon
#
# shellcheck shell=bash

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HARNESS_DIR/.." && pwd)"
# The daemon under test is the WORKING TREE copy, never the installed one.
DAEMON="${DAEMON:-$REPO/bin/agent-session-daemon}"

ST=""
PORT=8399
DPID=""
PASS=0
FAIL=0

harness_init() {
  ST="$1"
  PORT="${2:-8399}"
  trap 'stop_daemon' EXIT
}

# --- assertions -------------------------------------------------------------
ok() {   # ok <actual> <expected> <label>
  if [ "$1" = "$2" ]; then echo "    PASS $3"; PASS=$((PASS + 1));
  else echo "    FAIL $3 (got '$1' want '$2')"; FAIL=$((FAIL + 1)); fi
}
has() {  # has <text> <substring> <label>
  case "$1" in *"$2"*) echo "    PASS $3"; PASS=$((PASS + 1));;
    *) echo "    FAIL $3 (in: ${1:0:200})"; FAIL=$((FAIL + 1));; esac
}
hasnt() {
  case "$1" in *"$2"*) echo "    FAIL $3 (found '$2' in: ${1:0:200})"; FAIL=$((FAIL + 1));;
    *) echo "    PASS $3"; PASS=$((PASS + 1));; esac
}
finish() {
  echo
  if [ "$FAIL" -eq 0 ]; then echo "ALL PASS ($PASS checks)"; else echo "$FAIL FAILURES ($PASS passed)"; fi
  exit "$FAIL"
}

# --- json helpers -----------------------------------------------------------
# jget '<json>' "['a']['b']"  — the expression is python subscript syntax.
jget() {
  python3 -c "import json,sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
try: v = d$2
except Exception: v = ''
print('' if v is None else v)" <<<"$1"
}

# --- daemon lifecycle -------------------------------------------------------
reset_state() {
  rm -rf "$ST"
  mkdir -p "$ST/sessions" "$ST/archive" "$ST/web"
  cp "$REPO/web/index.html" "$ST/web/" 2>/dev/null || true
  : >"$ST/out"
  : >"$ST/pi-cmds"
}

start_daemon() {
  export PATH="$REPO/tests/fakebin:$PATH"
  export AGENT_SESSION_DIR="$ST"
  export AGENT_SESSION_WORKDIR="$ST"
  export AGENT_SESSION_ID="${AGENT_SESSION_ID:-watest}"
  export AGENT_SESSION_NAME="${AGENT_SESSION_NAME:-watest}"
  export AGENT_WEB_HOST=127.0.0.1
  export AGENT_WEB_PORT="$PORT"
  export AGENT_QUIET_MATRIX=1
  export AGENT_SETTLE_GRACE="${AGENT_SETTLE_GRACE:-2}"
  export FAKE_PI_STATE_LOG="$ST/pi-cmds"
  export FAKE_PI_ARGV="$ST/argv"
  export FAKE_PI_SESSION="${FAKE_PI_SESSION:-$ST/sessions/live.jsonl}"
  python3 "$DAEMON" >>"$ST/out" 2>&1 &
  DPID=$!
  local i
  for i in $(seq 1 80); do
    grep -q "listening on FIFO" "$ST/out" 2>/dev/null && break
    sleep 0.1
  done
  for i in $(seq 1 80); do
    curl -sf -o /dev/null -m 1 "http://127.0.0.1:$PORT/state" 2>/dev/null && break
    sleep 0.1
  done
  sleep "${START_GRACE:-0.4}"     # let the daemon record the active session
}
stop_daemon() {
  [ -n "$DPID" ] || return 0
  kill "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
  DPID=""
}

# --- http -------------------------------------------------------------------
api() {   # api <GET|POST> <path> [body] -> response body
  local method=$1 path=$2 body=${3:-}
  if [ "$method" = POST ]; then
    curl -s -m 25 -X POST "http://127.0.0.1:$PORT$path" \
         -H 'Content-Type: application/json' -d "$body"
  else
    curl -s -m 25 "http://127.0.0.1:$PORT$path"
  fi
}
code() {  # code <GET|POST> <path> [body] -> http status
  local method=$1 path=$2 body=${3:-}
  if [ "$method" = POST ]; then
    curl -s -m 25 -o /dev/null -w '%{http_code}' -X POST \
         "http://127.0.0.1:$PORT$path" -H 'Content-Type: application/json' -d "$body"
  else
    curl -s -m 25 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$path"
  fi
}
state_field() { local s; s=$(api GET /state); jget "$s" "$1"; }

# --- server-sent events -----------------------------------------------------
# sse_start must run BEFORE the action under test; sse_stop then greps $ST/sse.
sse_start() {
  curl -s -N -m 30 "http://127.0.0.1:$PORT/events" >"$ST/sse" 2>/dev/null &
  SSE_PID=$!
  sleep 0.4
}
sse_stop() {
  if [ -n "${SSE_PID:-}" ]; then
    kill "$SSE_PID" 2>/dev/null
    wait "$SSE_PID" 2>/dev/null   # only the curl; a bare `wait` waits for the daemon too
  fi
  SSE_PID=""
}

# --- fake pi introspection --------------------------------------------------
# Every command the fake pi received, one JSON object per line.
pi_cmd_types() { python3 -c "
import json,sys
for line in open('$ST/pi-cmds'):
    line = line.strip()
    if line:
        try: print(json.loads(line).get('type'))
        except Exception: pass" 2>/dev/null; }
pi_saw() { pi_cmd_types | grep -qx "$1" && echo yes || echo no; }
pi_count() { pi_cmd_types | grep -cx "$1"; }
# The sessionPath of the last switch_session the daemon asked for.
pi_last_switch() { python3 -c "
import json
last = ''
for line in open('$ST/pi-cmds'):
    line = line.strip()
    if not line: continue
    try: c = json.loads(line)
    except Exception: continue
    if c.get('type') == 'switch_session': last = c.get('sessionPath') or ''
print(last)" 2>/dev/null; }

# --- session fixtures -------------------------------------------------------
# seed_session <dir: sessions|archive> <filename> [more content lines]
seed_session() {
  local where=$1 fname=$2
  printf '{"type": "session", "version": 3, "id": "watest", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": "%s"}\n' "$ST" \
    >"$ST/$where/$fname"
}
seed_message() {   # append a message entry to a seeded transcript
  printf '%s\n' "$2" >>"$ST/$1"
}
