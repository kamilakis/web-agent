#!/usr/bin/env bash
# §22 self-update, daemon side: GET /update, POST /update/check, POST /update,
# and the health marker. The "remote" is a local bare repo; the updater is a
# stub (AGENT_UPDATE_CMD), so nothing is installed or restarted.
#
#     bash tests/update.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/update" "${TEST_PORT:-8387}"
export AGENT_UPDATE_CHECK=0          # checks only when a test asks for one
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A bare "origin", a scratch clone that pushes to it, and the checkout the
# daemon was installed from (build.json names it).
setup_repos() {
  local g="$ST/git"
  rm -rf "$g"; mkdir -p "$g"
  git init -q --bare -b master "$g/origin.git"
  git clone -q "$g/origin.git" "$g/dev" 2>/dev/null
  git -C "$g/dev" checkout -q -b master
  echo one >"$g/dev/f"; git -C "$g/dev" add f; git -C "$g/dev" commit -qm "first"
  git -C "$g/dev" push -q origin master
  git clone -q -b master "$g/origin.git" "$g/checkout"
  CHECKOUT="$g/checkout"
  printf '{"commit":"%s","built":"x","repo":"%s"}\n' \
    "$(git -C "$CHECKOUT" rev-parse --short HEAD)" "$CHECKOUT" >"$ST/build.json"
}
push_commit() {   # push_commit <subject>
  echo "$1" >>"$ST/git/dev/f"
  git -C "$ST/git/dev" commit -qam "$1"
  git -C "$ST/git/dev" push -q origin master
}
stub_updater() {
  printf '#!/bin/sh\necho started >>"%s/updater-calls"\n' "$ST" >"$ST/stub-update"
  chmod +x "$ST/stub-update"
  export AGENT_UPDATE_CMD="$ST/stub-update"
}
calls() { wc -l <"$ST/updater-calls" 2>/dev/null | tr -d ' ' || echo 0; }

echo "=== the daemon says when its build is up (what agent-update waits for)"
reset_state; setup_repos; stub_updater
FAKE_PI_SCENARIO=ok start_daemon
sleep 1
H=$(cat "$ST/health.json" 2>/dev/null)
has "$H" '"daemon"' "health.json names the daemon version"
has "$H" "\"commit\": \"$(git -C "$CHECKOUT" rev-parse --short HEAD)\"" "and the installed commit"

echo "=== up to date: nothing to offer"
U=$(api POST /update/check '{}')
ok "$(jget "$U" "['available']")" "False" "not available"
ok "$(jget "$U" "['can_update']")" "False" "no button"
ok "$(code POST /update '{}')" "409" "and POST /update refuses"
ok "$(calls)" "0" "without starting the updater"

echo "=== a new commit on origin/master is offered"
push_commit "move the archive button"
push_commit "smaller text"
sse_start
U=$(api POST /update/check '{}')
sleep 0.3; sse_stop
ok "$(jget "$U" "['available']")" "True" "available"
ok "$(jget "$U" "['behind']")" "2" "two commits behind"
ok "$(jget "$U" "['commits'][0]['subject']")" "smaller text" "newest first, with its subject"
ok "$(jget "$U" "['can_update']")" "True" "the button can work"
has "$(cat "$ST/sse")" '"update_available"' "the tabs are told"
ok "$(jget "$(api GET /update)" "['latest']")" "$(git -C "$ST/git/dev" rev-parse --short HEAD)" \
   "GET /update serves the last check"

echo "=== Update starts the updater unit, and says so"
sse_start
R=$(api POST /update '{}')
sleep 0.3; sse_stop
ok "$(code GET /update)" "200" "GET /update answers"
has "$R" '"ok": true' "accepted"
ok "$(calls)" "1" "the updater was started once"
has "$(cat "$ST/sse")" '"update_started"' "update_started broadcast"
has "$(cat "$ST/out")" "UPDATE STARTED" "logged"

echo "=== a run in progress: asked first, unless forced"
echo '{"state":"ok","stage":"done","finished":1}' >"$ST/update.json"
stop_daemon
: >"$ST/updater-calls"
FAKE_PI_SCENARIO=hang start_daemon
api POST /update/check '{}' >/dev/null
api POST /prompt '{"message":"long"}' >/dev/null
sleep 0.5
R=$(api POST /update '{}')
has "$R" "busy" "refused while a reply is running"
ok "$(calls)" "0" "updater not started"
R=$(api POST /update '{"force":true}')
has "$R" '"ok": true' "forced after the user confirmed"
ok "$(calls)" "1" "updater started"
stop_daemon

echo "=== an update already running is not started twice"
printf '{"state":"running","stage":"test","updated":%s}\n' "$(date +%s)" >"$ST/update.json"
: >"$ST/updater-calls"
FAKE_PI_SCENARIO=ok start_daemon
api POST /update/check '{}' >/dev/null
ok "$(code POST /update '{}')" "409" "409"
ok "$(calls)" "0" "not started"
ok "$(jget "$(api GET /update)" "['run']['stage']")" "test" "GET /update carries the updater's progress"
stop_daemon
rm -f "$ST/update.json"

echo "=== a checkout the updater would refuse is reported, not offered"
echo local-edit >>"$CHECKOUT/f"
FAKE_PI_SCENARIO=ok start_daemon
U=$(api POST /update/check '{}')
ok "$(jget "$U" "['available']")" "True" "still says there is an update"
ok "$(jget "$U" "['can_update']")" "False" "but no button"
has "$(jget "$U" "['blocked']")" "uncommitted changes" "and says why"
ok "$(code POST /update '{}')" "409" "POST /update refuses"
git -C "$CHECKOUT" checkout -q -- f
git -C "$CHECKOUT" checkout -q -b other
U=$(api POST /update/check '{}')
has "$(jget "$U" "['blocked']")" "not 'master'" "another branch is refused too"
git -C "$CHECKOUT" checkout -q master
stop_daemon

echo "=== no checkout recorded (a tarball or hand-copied install)"
reset_state; stub_updater
printf '{"commit":"unknown","built":"x","repo":""}\n' >"$ST/build.json"
FAKE_PI_SCENARIO=ok start_daemon
U=$(api POST /update/check '{}')
has "$(jget "$U" "['error']")" "no git checkout" "says there is nothing to update from"
ok "$(code POST /update '{}')" "409" "and refuses"
stop_daemon

finish
