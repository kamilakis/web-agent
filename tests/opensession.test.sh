#!/usr/bin/env bash
# Part A: resuming a past session (docs/spec-resume-session.md §6, T1-T8 + T13).
#
# Runs a throwaway daemon against the fake pi. Nothing here touches the live
# agent: separate state dir, port and FIFO.
#
#     bash tests/opensession.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/opensession" "${TEST_PORT:-8399}"

count_active() { python3 -c "
import json, sys
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
except Exception:
    d = {}
print(sum(1 for s in d.get('sessions', []) if s.get('active')))"; }

echo "=== T1: resume a sessions/ transcript while idle"
reset_state
seed_session sessions target.jsonl
seed_session sessions other.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok start_daemon
BEFORE=$(state_field "['sessionFile']")
sse_start
R=$(api POST /opensession '{"file":"target.jsonl","dir":"sessions"}')
sleep 0.3; sse_stop
ok "$(jget "$R" "['ok']")" "True" "200 + ok"
ok "$(jget "$R" "['newFile']")" "$ST/sessions/target.jsonl" "newFile is the requested transcript"
ok "$(jget "$R" "['oldFile']")" "$BEFORE" "oldFile is the previous transcript"
ok "$(state_field "['sessionFile']")" "$ST/sessions/target.jsonl" "/state agrees"
ok "$(cat "$ST/active-session" 2>/dev/null)" "$ST/sessions/target.jsonl" "active-session record updated"
ok "$(pi_last_switch)" "$ST/sessions/target.jsonl" "pi was asked to switch to it"
has "$(cat "$ST/sse" 2>/dev/null)" '"session_switched"' "SSE session_switched broadcast"
has "$(cat "$ST/out")" "SESSION OPENED" "logged SESSION OPENED"
stop_daemon

echo "=== T2: resume an archive/ transcript — it un-archives"
reset_state
seed_session archive kept.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok start_daemon
R=$(api POST /opensession '{"file":"kept.jsonl","dir":"archive"}')
ok "$(jget "$R" "['ok']")" "True" "200 + ok"
ok "$(jget "$R" "['unarchived']")" "True" "reports unarchived"
ok "$(jget "$R" "['newFile']")" "$ST/sessions/kept.jsonl" "newFile is the sessions/ path"
[ -f "$ST/sessions/kept.jsonl" ] && ok yes yes "file now lives in sessions/" || ok no yes "file now lives in sessions/"
[ -f "$ST/archive/kept.jsonl" ] && ok yes no "and is gone from archive/" || ok no no "and is gone from archive/"
ok "$(cat "$ST/active-session" 2>/dev/null)" "$ST/sessions/kept.jsonl" "record holds the sessions/ path"
ok "$(pi_last_switch)" "$ST/sessions/kept.jsonl" "pi switched to the sessions/ path"
ok "$(count_active <<<"$(api GET /sessions)")" "1" "listed exactly once, as active"
stop_daemon

echo "=== T3: the same, but pi refuses the switch — the file goes back"
for mode in fail cancel; do
  reset_state
  seed_session archive kept.jsonl
  FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=$mode start_daemon
  R=$(api POST /opensession '{"file":"kept.jsonl","dir":"archive"}')
  has "$R" "error" "switch=$mode: reports an error"
  [ -f "$ST/archive/kept.jsonl" ] && ok yes yes "switch=$mode: file moved back to archive/" \
                                  || ok no yes "switch=$mode: file moved back to archive/"
  [ -f "$ST/sessions/kept.jsonl" ] && ok yes no "switch=$mode: nothing left behind in sessions/" \
                                   || ok no no "switch=$mode: nothing left behind in sessions/"
  stop_daemon
done

echo "=== T4: collision — a same-named file already in sessions/"
reset_state
seed_session archive dup.jsonl
seed_session sessions dup.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok start_daemon
C=$(code POST /opensession '{"file":"dup.jsonl","dir":"archive"}')
ok "$C" "409" "refuses with 409"
ok "$(test -f "$ST/archive/dup.jsonl" && echo yes)" "yes" "archive copy untouched"
ok "$(pi_count switch_session)" "0" "pi was never asked to switch"
ok "$(pi_count abort)" "0" "nothing was aborted"
stop_daemon

echo "=== T5: opening the live session while a run is active (B3)"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_SWITCH=ok start_daemon
LIVE=$(state_field "['sessionFile']")
api POST /prompt '{"message":"hold the line"}' >/dev/null
sleep 1.0
R=$(api POST /opensession "{\"file\":\"$(basename "$LIVE")\",\"dir\":\"sessions\"}")
has "$R" "already open" "refuses to re-open, while busy"
ok "$(pi_count abort)" "0" "the running reply was NOT killed (B3)"
stop_daemon

echo "=== T6: not a resumable session file (B4)"
reset_state
: >"$ST/sessions/empty.jsonl"
printf 'this is not json\n' >"$ST/sessions/garbage.jsonl"
seed_session sessions good.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok start_daemon
ok "$(code POST /opensession '{"file":"empty.jsonl","dir":"sessions"}')" "422" "empty file -> 422"
ok "$(code POST /opensession '{"file":"garbage.jsonl","dir":"sessions"}')" "422" "garbage -> 422"
ok "$(pi_count switch_session)" "0" "pi never received switch_session"
ok "$(code POST /opensession '{"file":"good.jsonl","dir":"sessions"}')" "200" "a good file still resumes"
stop_daemon

echo "=== T7: the vision cache is re-queried after a switch (B1)"
reset_state
seed_session sessions target.jsonl
# pi starts vision-capable, then a switch silently reverts it to text-only
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok \
  FAKE_PI_MODEL_INPUT='["text", "image"]' \
  FAKE_PI_MODEL_AFTER_SWITCH='{"id": "text-only", "input": ["text"]}' \
  AGENT_VISION_MODEL=fake/fake-vision start_daemon
IMG='{"message":"look at this","images":[{"type":"image","mimeType":"image/jpeg","data":"aGk="}]}'
# first image: the cache is cold, the model can see, so nothing switches
api POST /prompt "$IMG" >/dev/null
sleep 0.8
ok "$(pi_count set_model)" "0" "no auto-switch while the model is vision-capable"
api POST /opensession '{"file":"target.jsonl","dir":"sessions"}' >/dev/null
api POST /prompt "$IMG" >/dev/null
sleep 1.0
ok "$(pi_count set_model)" "1" "after a switch the capability is re-checked (B1)"
stop_daemon

echo "=== T8: a Siri run interrupted by a switch is answered (B8)"
reset_state
seed_session sessions target.jsonl
FAKE_PI_SCENARIO=hang FAKE_PI_SWITCH=ok FAKE_PI_ABORT=silent start_daemon
rm -f "$ST/results/9001.result"
printf '{"id":"9001","prompt":"how many hosts"}\n' >"$ST/in.fifo"
sleep 1.0
R=$(api POST /opensession '{"file":"target.jsonl","dir":"sessions"}')
ok "$(jget "$R" "['ok']")" "True" "the switch itself succeeds"
sleep 0.6
if [ -f "$ST/results/9001.result" ]; then
  ok yes yes "the Siri caller got a result file instead of a timeout"
  has "$(cat "$ST/results/9001.result")" "Interrupted" "and it says what happened"
else
  ok no yes "the Siri caller got a result file instead of a timeout"
  ok "" "Interrupted" "and it says what happened"
fi
stop_daemon

echo "=== T13: bad requests are still rejected"
reset_state
seed_session sessions ok.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok start_daemon
ok "$(code POST /opensession '{"file":"../../etc/passwd","dir":"sessions"}')" "400" "traversal"
ok "$(code POST /opensession '{"file":"nope.jsonl","dir":"sessions"}')" "404" "missing"
ok "$(code POST /opensession '{"file":"ok.jsonl","dir":"../.."}')" "400" "bad dir"
ok "$(code POST /opensession '{"file":"ok.txt","dir":"sessions"}')" "400" "non-jsonl"
ok "$(code GET /session?file=../../etc/passwd&dir=sessions)" "400" "GET /session traversal"
stop_daemon

echo "=== B6: /sessions flags the active session by path, not basename"
reset_state
seed_session archive dup2.jsonl
seed_session sessions dup2.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=ok FAKE_PI_SESSION="$ST/sessions/dup2.jsonl" start_daemon
ok "$(count_active <<<"$(api GET /sessions)")" "1" "exactly one active, not two"
stop_daemon

finish
