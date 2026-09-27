#!/usr/bin/env bash
# The review's lower-severity fixes: stopped runs are not answers, switches
# tell interrupted callers, slow SSE clients resync, rejections only reset
# their own dispatch, the vision switch must land, an archive-move failure is
# still recorded, /usage survives bad data, dialogs honour an extension's own
# timeout, /session keeps the newest messages, the Matrix listener follows
# AGENT_SESSION_DIR.
#
#     bash tests/hardening.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/hardening" "${TEST_PORT:-8389}"

siri() {   # siri <id> <prompt> — what agent-task writes to the FIFO
  local b64; b64=$(printf '%s' "$2" | base64 -w0)
  timeout 5 bash -c 'printf "%s\n" "$1" > "$2"' _ \
    "{\"id\":\"$1\",\"prompt_b64\":\"$b64\"}" "$ST/in.fifo"
}

echo "=== a stopped Siri run is said to be stopped, not delivered as the answer"
reset_state
FAKE_PI_SCENARIO=hang start_daemon
siri s-1 "long task"
sleep 1
api POST /abort >/dev/null
sleep 1
has "$(cat "$ST/results/s-1.result" 2>/dev/null)" "Stopped before it finished" "the caller hears it was stopped"
has "$(cat "$ST/tasks/s-1.log" 2>/dev/null)" "status: aborted" "the task log says aborted, not ok"
has "$(cat "$ST/out")" "RUN ABORTED" "and the daemon logged it"
stop_daemon

echo "=== /newsession tells an interrupted Siri caller (B8, as /opensession does)"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_ABORT=silent start_daemon
siri s-2 "long task"
sleep 1
api POST /newsession '{}' >/dev/null
has "$(cat "$ST/results/s-2.result" 2>/dev/null)" "Interrupted" "the caller is told the run was cut short"
stop_daemon

echo "=== the vision auto-switch must actually land"
reset_state
FAKE_PI_SCENARIO=ok FAKE_PI_MODEL_INPUT='["text"]' start_daemon
R=$(api POST /prompt '{"message":"look","images":[{"type":"image","data":"aGk=","mimeType":"image/png"}]}')
has "$R" "still reports no image input" "a switch that leaves a text-only model is an error"
ok "$(pi_count prompt)" "0" "and the picture is not sent to a model that cannot see it"
stop_daemon

echo "=== an archive move that fails still records the switch that happened"
reset_state
seed_session sessions live.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" start_daemon
rm -rf "$ST/archive"; : >"$ST/archive"          # a file where the dir should be
sse_start
R=$(api POST /archive '{}')
sleep 0.3; sse_stop
has "$R" "archive move failed" "the error is reported"
NEW=$(state_field "['sessionFile']")
ok "$(cat "$ST/active-session")" "$(realpath "$NEW")" "the record follows pi onto the new file"
has "$(cat "$ST/sse")" '"session_switched"' "and the tabs are told"
stop_daemon

echo "=== /usage survives a transcript it cannot sum, and recovers"
reset_state
seed_session sessions live.jsonl
seed_message sessions/live.jsonl '{"type": "message", "message": {"role": "assistant", "usage": {"input": "oops", "output": 1, "cost": {"total": 0.01}}}}'
AGENT_USAGE_REFRESH=1 AGENT_USAGE_CMD= FAKE_PI_SCENARIO=ok \
  FAKE_PI_SESSION="$ST/sessions/live.jsonl" start_daemon
sleep 1.5
has "$(cat "$ST/out")" "usage refresh failed" "the bad data is logged"
printf '%s\n' '{"type": "session", "version": 3, "id": "watest", "timestamp": "2026-01-01T00:00:00.000Z"}' \
  '{"type": "message", "message": {"role": "assistant", "usage": {"input": 5, "output": 1, "cost": {"total": 0.02}}}}' \
  >"$ST/sessions/live.jsonl"
sleep 2
ok "$(jget "$(api GET /usage)" "['session']['cost']")" "0.02" "and the next refresh works (the thread lived)"
stop_daemon

echo "=== /session shows the NEWEST messages of a long transcript"
reset_state
seed_session sessions long.jsonl
python3 - "$ST/sessions/long.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    for i in range(4100):
        f.write(json.dumps({"type": "message", "message": {"role": "user",
                "content": [{"type": "text", "text": f"msg {i}"}]}}) + "\n")
PY
FAKE_PI_SCENARIO=ok start_daemon
S=$(api GET "/session?file=long.jsonl&dir=sessions")
ok "$(jget "$S" "['messages'][-1]['content'][0]['text']")" "msg 4099" "the last message is there"
ok "$(jget "$S" "['messages'][0]['content'][0]['text']")" "msg 100" "the cap drops the oldest"
stop_daemon

echo "=== daemon internals: slow SSE clients, rejections, extension timeouts"
reset_state
OUT=$(AGENT_SESSION_DIR="$ST" AGENT_SESSION_WORKDIR="$ST" AGENT_UI_TIMEOUT=90 \
      python3 - "$DAEMON" <<'PY' 2>&1
import importlib.machinery, importlib.util, queue, sys, time
loader = importlib.machinery.SourceFileLoader("daemon", sys.argv[1])
spec = importlib.util.spec_from_loader("daemon", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
m.log = lambda *a: None
d = m.Daemon()
sent = []
d.send_cmd = sent.append

# a client that cannot keep up is dropped, not silently fed a gappy stream
q = queue.Queue(maxsize=1); q.overflowed = False
d.clients.append(q)
d.broadcast({"type": "a"}); d.broadcast({"type": "b"})
print("dropped", q not in d.clients and q.overflowed)

# a rejected steer must not clear another source's pending dispatch
d.dispatch_pending, d.pending_start_source = True, "siri"
d.dispatch_map["fifo-1"] = {"source": "siri", "pid": "x", "prompt": "p", "attempts": 0}
d.on_prompt_rejected("web-9", "nope")
print("kept", d.dispatch_pending and d.pending_start_source == "siri")

# an extension's own, shorter timeout: that is the deadline, and pi closes it
m.threading.Thread = lambda *a, **k: type("T", (), {"start": lambda s: None})()
d.on_ui_request({"type": "extension_ui_request", "id": "u1", "method": "select",
                 "title": "t", "options": ["a"], "timeout": 5000})
req = d.ui_pending["u1"]
print("deadline", 4 < req["deadline"] - req["asked"] < 6)
req["deadline"] = time.time()          # expire it now
d.clients.append(queue.Queue())        # somebody is watching
d._ui_watchdog("u1")
print("pi-closes", "u1" not in d.ui_pending and not sent)
PY
)
has "$OUT" "dropped True" "a client that falls behind is dropped so it reconnects and resyncs"
has "$OUT" "kept True" "a rejected steer leaves another source's pending dispatch alone"
has "$OUT" "deadline True" "an extension's shorter timeout becomes the deadline"
has "$OUT" "pi-closes True" "and when it passes the daemon does not answer for pi"

echo "=== the Matrix listener follows AGENT_SESSION_DIR"
OUT=$(AGENT_SESSION_DIR="$ST/elsewhere" AGENT_MATRIX_STATE_DIR="$ST/mx" python3 - "$REPO/bin/agent-matrix-listener" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("listener", sys.argv[1])
spec = importlib.util.spec_from_loader("listener", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print(m.FIFO)
PY
)
ok "$OUT" "$ST/elsewhere/in.fifo" "its FIFO is the daemon's"

finish
