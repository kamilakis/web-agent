#!/usr/bin/env bash
# §17.7 / T10: a restart resumes the RECORDED active transcript, not the oldest
# file sharing the session id. Also covers the record after /opensession.
#
#     bash tests/resume.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/resume" "${TEST_PORT:-8397}"

seed_at() {   # seed_at <filename> <touch -d spec> — a dated, valid transcript
  seed_session sessions "$1"
  touch -d "$2" "$ST/sessions/$1"
}
argv_last() { tail -1 "$ST/argv" 2>/dev/null || echo "(no argv)"; }

echo "=== 1. fresh start: nothing to resume -> --session-id + -n"
reset_state
FAKE_PI_SCENARIO=ok start_daemon
A=$(argv_last); stop_daemon
has "$A" "--session-id watest" "creates the session by id"
hasnt "$A" "--session /" "does not try to resume a file"
has "$A" "-n watest" "names the new session"
ok "$(cat "$ST/active-session" 2>/dev/null)" "$ST/sessions/live.jsonl" "recorded the file pi reported"

echo "=== 2. restart resumes the RECORDED file even though an older namesake exists"
reset_state
seed_at 2026-01-01T00-00-00-000Z_watest.jsonl "2026-01-01 00:00"
seed_at 2026-09-25T04-44-27-413Z_watest.jsonl "2026-09-25 04:44"
printf '%s\n' "$ST/sessions/2026-09-25T04-44-27-413Z_watest.jsonl" >"$ST/active-session"
FAKE_PI_SESSION="$ST/sessions/2026-09-25T04-44-27-413Z_watest.jsonl" start_daemon
A=$(argv_last); stop_daemon
has "$A" "--session $ST/sessions/2026-09-25T04-44-27-413Z_watest.jsonl" "resumes the recorded file"

echo "=== 3. a record pointing at a deleted file falls back to the newest valid one"
reset_state
seed_at 2026-01-01T00-00-00-000Z_watest.jsonl "2026-01-01 00:00"
seed_at 2026-09-25T04-44-27-413Z_watest.jsonl "2026-09-25 04:44"
printf '%s\n' "$ST/sessions/gone.jsonl" >"$ST/active-session"
FAKE_PI_SESSION="$ST/sessions/2026-09-25T04-44-27-413Z_watest.jsonl" start_daemon
A=$(argv_last); stop_daemon
has "$A" "--session $ST/sessions/2026-09-25T04-44-27-413Z_watest.jsonl" "falls back to the newest valid transcript"

echo "=== 4. empty and unparseable files are skipped"
reset_state
: >"$ST/sessions/2026-09-25T01-00-00-000Z_watest.jsonl"
printf 'not json\n' >"$ST/sessions/2026-09-25T02-00-00-000Z_watest.jsonl"
seed_at 2026-09-25T03-00-00-000Z_watest.jsonl "2026-09-25 03:00"
FAKE_PI_SESSION="$ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" start_daemon
A=$(argv_last); stop_daemon
has "$A" "--session $ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" "picks the newest VALID file"

echo "=== 5. a record outside sessions/ and archive/ is refused"
reset_state
seed_at 2026-09-25T03-00-00-000Z_watest.jsonl "2026-09-25 03:00"
printf '/etc/passwd\n' >"$ST/active-session"
FAKE_PI_SESSION="$ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" start_daemon
A=$(argv_last); stop_daemon
hasnt "$A" "--session /etc/passwd" "does not open a file outside the session dirs"

echo "=== 6. /opensession and /newsession both update the record"
reset_state
seed_session sessions pick.jsonl
FAKE_PI_SCENARIO=ok start_daemon
api POST /opensession '{"file":"pick.jsonl","dir":"sessions"}' >/dev/null
ok "$(cat "$ST/active-session")" "$ST/sessions/pick.jsonl" "opensession recorded the opened file"
NEW=$(api POST /newsession '{"name":"Brand new"}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("newFile") or "")')
ok "$(cat "$ST/active-session")" "$NEW" "newsession recorded the crafted file"
stop_daemon

echo "=== 7. T10: the recorded file wins again on the next restart"
reset_state
seed_at 2026-01-01T00-00-00-000Z_watest.jsonl "2026-01-01 00:00"
seed_at 2026-09-25T03-00-00-000Z_watest.jsonl "2026-09-25 03:00"
printf '%s\n' "$ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" >"$ST/active-session"
FAKE_PI_SESSION="$ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" start_daemon
A=$(argv_last); stop_daemon
has "$A" "--session $ST/sessions/2026-09-25T03-00-00-000Z_watest.jsonl" "keeps the active session across restarts"

finish
