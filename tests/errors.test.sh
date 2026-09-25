#!/usr/bin/env bash
# §17.4 regression: a failed run is surfaced, never a silent empty answer.
#
#     bash tests/errors.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/errors" "${TEST_PORT:-8398}"
# The Siri result file is deleted once the grace window closes (the caller is
# assumed to have gone away and the answer goes to Matrix instead). These cases
# are about what is delivered, so keep the window open.
export AGENT_SETTLE_GRACE=30

task_status() { grep -m1 '^status:' "$ST"/tasks/*.log 2>/dev/null | cut -d' ' -f2; }

echo "=== an errored run is visible in the task log and over SSE (web)"
reset_state
FAKE_PI_SCENARIO=error start_daemon
sse_start
api POST /prompt '{"message":"hello"}' >/dev/null
sleep 2.0
sse_stop
ok "$(task_status)" "error" "task log records status: error"
has "$(cat "$ST/out")" "RUN ERROR" "the daemon logged RUN ERROR"
has "$(cat "$ST/sse")" '"stopReason": "error"' "the browser got the error over SSE"
stop_daemon

echo "=== an errored Siri run gets a spoken failure, not silence"
reset_state
FAKE_PI_SCENARIO=errorbare start_daemon
rm -f "$ST"/results/*.result
printf '{"id":"7001","prompt":"status"}\n' >"$ST/in.fifo"
sleep 1.5
has "$(cat "$ST/results/7001.result" 2>/dev/null)" "The agent failed" "result file carries the failure"
stop_daemon

echo "=== a retried run recovers"
reset_state
FAKE_PI_SCENARIO=retry start_daemon
api POST /prompt '{"message":"hello"}' >/dev/null
sleep 2.0
ok "$(task_status)" "ok" "task log records status: ok"
stop_daemon

echo "=== a healthy Siri run is delivered"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
rm -f "$ST"/results/*.result
printf '{"id":"7002","prompt":"hello"}\n' >"$ST/in.fifo"
sleep 1.5
has "$(cat "$ST/results/7002.result" 2>/dev/null)" "All good." "result file carries the answer"
stop_daemon

finish
