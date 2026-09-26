#!/usr/bin/env bash
# Versioning: GET /version tells the dashboard what the daemon is (§18.5).
#
#     bash tests/version.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/version" "${TEST_PORT:-8394}"

echo "=== /version reports the daemon version and the recorded commit"
reset_state
printf '{"commit":"abc1234","built":"2026-09-26T13:00:00+03:00"}\n' >"$ST/build.json"
FAKE_PI_SCENARIO=ok start_daemon
V=$(api GET /version)
has "$V" '"daemon"' "reports a daemon version"
has "$V" '"commit": "abc1234"' "reports the commit install.sh recorded"
has "$V" '"built"' "reports when it was installed"
ok "$(code GET /version)" "200" "200 OK"
stop_daemon

echo "=== a missing build.json is not an error (hand-copied daemon)"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
V=$(api GET /version)
has "$V" '"daemon"' "still reports its own version"
ok "$(jget "$V" "['commit']")" "" "commit is null"
ok "$(code GET /version)" "200" "200 OK"
stop_daemon

echo "=== /state is untouched by all this (it stays a pi pass-through)"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
has "$(api GET /state)" '"sessionFile"' "/state still carries pi's state"
ok "$(api GET /state | grep -c '\"daemon\"')" "0" "and nothing was merged into it"
stop_daemon

finish
