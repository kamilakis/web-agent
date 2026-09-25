#!/usr/bin/env bash
# Part C: deleting a session (§9, D1-D6 + D8).
#
#     bash tests/delete.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/delete" "${TEST_PORT:-8395}"
# One-second janitor so D6 does not wait 15s for a purge tick.
export AGENT_JANITOR_INTERVAL=1

trash_count() { find "$ST/trash" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "=== D1: delete a Previous session"
reset_state
seed_session sessions doomed.jsonl
seed_session sessions keep.jsonl
FAKE_PI_SCENARIO=ok start_daemon
sse_start
R=$(api POST /deletesession '{"file":"doomed.jsonl","dir":"sessions"}')
sleep 0.3; sse_stop
ok "$(jget "$R" "['ok']")" "True" "200 + ok"
ok "$(test -f "$ST/sessions/doomed.jsonl" && echo yes || echo no)" "no" "gone from sessions/"
ok "$(trash_count)" "1" "one file in the trash"
has "$(ls "$ST/trash" 2>/dev/null)" "doomed-" "named after the original, with a timestamp"
has "$(cat "$ST/out")" "SESSION DELETED" "logged SESSION DELETED"
has "$(cat "$ST/sse" 2>/dev/null)" '"session_deleted"' "SSE session_deleted broadcast"
ok "$(api GET /sessions | grep -c doomed)" "0" "no longer listed"
stop_daemon

echo "=== D2: delete an Archived session"
reset_state
seed_session archive old.jsonl
FAKE_PI_SCENARIO=ok start_daemon
R=$(api POST /deletesession '{"file":"old.jsonl","dir":"archive"}')
ok "$(jget "$R" "['ok']")" "True" "200 + ok"
ok "$(test -f "$ST/archive/old.jsonl" && echo yes || echo no)" "no" "gone from archive/"
ok "$(trash_count)" "1" "in the trash"
stop_daemon

echo "=== D3: the live session cannot be deleted"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
LIVE=$(basename "$(state_field "['sessionFile']")")
C=$(code POST /deletesession "{\"file\":\"$LIVE\",\"dir\":\"sessions\"}")
ok "$C" "409" "refused with 409"
ok "$(test -f "$ST/sessions/$LIVE" && echo yes || echo no)" "yes" "the file is untouched"
ok "$(trash_count)" "0" "nothing was trashed"
has "$(api POST /deletesession "{\"file\":\"$LIVE\",\"dir\":\"sessions\"}")" "live session" "says why"
stop_daemon

echo "=== D4: a delete cannot race a switch"
reset_state
seed_session sessions target.jsonl
FAKE_PI_SCENARIO=ok FAKE_PI_SWITCH=timeout start_daemon
seed_session sessions other.jsonl
( api POST /opensession '{"file":"target.jsonl","dir":"sessions"}' >/dev/null 2>&1 & )
sleep 1.2      # the switch is now blocked waiting on pi
C=$(code POST /deletesession '{"file":"other.jsonl","dir":"sessions"}')
ok "$C" "409" "refused while a switch is in progress"
ok "$(test -f "$ST/sessions/other.jsonl" && echo yes || echo no)" "yes" "the file is untouched"
stop_daemon

echo "=== D5: bad requests are rejected"
reset_state
seed_session sessions ok.jsonl
FAKE_PI_SCENARIO=ok start_daemon
ok "$(code POST /deletesession '{"file":"../../etc/passwd","dir":"sessions"}')" "400" "traversal"
ok "$(code POST /deletesession '{"file":"nope.jsonl","dir":"sessions"}')" "404" "missing"
ok "$(code POST /deletesession '{"file":"ok.jsonl","dir":"../.."}')" "400" "bad dir"
ok "$(code POST /deletesession '{"file":"ok.txt","dir":"sessions"}')" "400" "non-jsonl"
stop_daemon

echo "=== D6: the janitor ages the trash out (AGENT_TRASH_DAYS)"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
mkdir -p "$ST/trash"
touch "$ST/trash/recent-1.jsonl"; touch -d "29 days ago" "$ST/trash/recent-1.jsonl"
touch "$ST/trash/stale-2.jsonl";  touch -d "31 days ago" "$ST/trash/stale-2.jsonl"
sleep 2.5      # a couple of janitor ticks
ok "$(test -f "$ST/trash/stale-2.jsonl" && echo yes || echo no)" "no" "a 31-day-old transcript is purged"
ok "$(test -f "$ST/trash/recent-1.jsonl" && echo yes || echo no)" "yes" "a 29-day-old one is kept"
has "$(cat "$ST/out")" "TRASH PURGED" "logged the purge"
stop_daemon

echo "=== D8: a restart after deleting still resumes the recorded transcript"
reset_state
seed_session sessions oldest.jsonl
FAKE_PI_SCENARIO=ok start_daemon
api POST /opensession '{"file":"oldest.jsonl","dir":"sessions"}' >/dev/null
seed_session sessions newer.jsonl      # newest mtime, but NOT the recorded one
sleep 0.2
api POST /deletesession '{"file":"newer.jsonl","dir":"sessions"}' >/dev/null
REC=$(cat "$ST/active-session")
stop_daemon
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$REC" start_daemon
A=$(tail -1 "$ST/argv")
has "$A" "--session $REC" "resumes the recorded file, which was not the deleted one"
stop_daemon

finish
