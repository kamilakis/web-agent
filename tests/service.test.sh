#!/usr/bin/env bash
# The always-on contract: the daemon must come up in the environment a
# boot-time `systemctl --user` unit actually gets.
#
# On 2026-09-21 11:07:26 it did not. `pi` lives in ~/.local/bin, the user
# manager started before any login had imported the environment, its PATH was
# systemd's default, and the daemon died with `FileNotFoundError: 'pi'` — coming
# back only because systemd retried six seconds later. These cases run the
# daemon with a PATH deliberately stripped of every place pi could live.
#
#     bash tests/service.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/service" "${TEST_PORT:-8393}"

# A daemon of its own, so we control what sits next to it (BIN_DIR).
LAYOUT="$ST/layout"
install_daemon() {   # install_daemon <dir>
  mkdir -p "$1"
  install -m 755 "$DAEMON" "$1/agent-session-daemon"
}
BARE_PATH=/usr/bin:/bin      # no ~/.local/bin, no tests/fakebin

run_one() {          # run_one <label> <bin-dir> <home> <extra env…>
  local label=$1 bindir=$2 fakehome=$3; shift 3
  local st="$ST/$label"
  rm -rf "$st"; mkdir -p "$st/sessions" "$st/archive" "$st/web" "$fakehome"
  cp "$REPO/web/index.html" "$st/web/" 2>/dev/null || true
  env -i PATH="$BARE_PATH" HOME="$fakehome" \
      AGENT_SESSION_DIR="$st" AGENT_SESSION_WORKDIR="$st" \
      AGENT_SESSION_ID=watest AGENT_WEB_HOST=127.0.0.1 AGENT_WEB_PORT="$PORT" \
      AGENT_QUIET_MATRIX=1 FAKE_PI_SESSION="$st/sessions/live.jsonl" \
      FAKE_PI_STATE_LOG="$st/pi-cmds" \
      "$@" python3 "$bindir/agent-session-daemon" >"$st/out" 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 60); do
    grep -q "listening on FIFO" "$st/out" 2>/dev/null && break
    sleep 0.1
  done
  local verdict
  if grep -q "listening on FIFO" "$st/out"; then
    curl -sf -m 5 "http://127.0.0.1:$PORT/state" >/dev/null 2>&1 \
      && verdict="up" || verdict="no-http"
  else
    verdict="down"
    # It is still in its retry backoff. Let it run out and fail on its own, so
    # the test can see the reason it gave up rather than killing it mid-retry.
    local j
    for j in $(seq 1 120); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "$verdict"
}

echo "=== A: daemon and pi installed side by side (the real layout)"
install_daemon "$LAYOUT/a"
install -m 755 "$REPO/tests/fakebin/pi" "$LAYOUT/a/pi"
OUT=$(run_one a "$LAYOUT/a" "$ST/home-a")
st="$ST/a"
ok "$(echo "$OUT" | head -1)" "up" "comes up with ~/.local/bin off PATH"
has "$(cat "$st/out")" "starting pi:" "pi was started"
hasnt "$(cat "$st/out")" "FileNotFoundError" "no FileNotFoundError"
has "$(cat "$st/out")" "$LAYOUT/a/pi" "and it ran the pi next to it"

echo "=== B: pi only via the ~/.local/bin fallback"
install_daemon "$LAYOUT/b"
mkdir -p "$ST/home-b/.local/bin"
install -m 755 "$REPO/tests/fakebin/pi" "$ST/home-b/.local/bin/pi"
OUT=$(run_one b "$LAYOUT/b" "$ST/home-b")
st="$ST/b"
ok "$(echo "$OUT" | head -1)" "up" "comes up with pi only in \$HOME/.local/bin"
has "$(cat "$st/out")" "$ST/home-b/.local/bin/pi" "found it there"

echo "=== C: AGENT_PI_BIN wins over everything"
install_daemon "$LAYOUT/c"
OUT=$(run_one c "$LAYOUT/c" "$ST/home-c" AGENT_PI_BIN="$REPO/tests/fakebin/pi")
st="$ST/c"
ok "$(echo "$OUT" | head -1)" "up" "comes up on the override alone"
has "$(cat "$st/out")" "$REPO/tests/fakebin/pi" "used the configured binary"

echo "=== D: with pi nowhere, it says so and gives up (systemd then retries)"
install_daemon "$LAYOUT/d"
OUT=$(run_one d "$LAYOUT/d" "$ST/home-d")
st="$ST/d"
ok "$(echo "$OUT" | head -1)" "down" "does not come up"
has "$(cat "$st/out")" "pi not runnable yet" "retried before failing"
has "$(cat "$st/out")" "FileNotFoundError" "and reported the real cause"

finish
