#!/usr/bin/env bash
# §22 bin/agent-update against a toy checkout: fast-forward, test, install,
# wait for the new build's health.json, roll back when it never comes, and
# refuse anything that is not a clean fast-forward. The toy repo's own
# install.sh and tests/run-all.sh stand in for the real ones, so nothing here
# installs or restarts anything real.
#
#     bash tests/agent-update.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/agent-update" "${TEST_PORT:-8386}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
UPDATER="$REPO/bin/agent-update"

setup() {
  reset_state
  local g="$ST/git"
  mkdir -p "$g"
  git init -q --bare -b master "$g/origin.git"
  git clone -q "$g/origin.git" "$g/dev" 2>/dev/null
  git -C "$g/dev" checkout -q -b master
  mkdir -p "$g/dev/tests"
  # the stand-in installer: records the install, writes build.json the way the
  # real one does, and plays the restarted daemon by writing health.json —
  # unless this commit is listed in $ST/broken (a build that never comes up)
  cat >"$g/dev/install.sh" <<'SH'
#!/bin/sh
c=$(git rev-parse --short HEAD)
echo "$c" >>"$TEST_ST/installs"
printf '{"commit":"%s","built":"x","repo":"%s"}\n' "$c" "$(pwd)" >"$TEST_ST/build.json"
grep -qx "$c" "$TEST_ST/broken" 2>/dev/null && exit 0
printf '{"commit":"%s","at":%s}\n' "$c" "$(date +%s)" >"$TEST_ST/health.json"
SH
  # the stand-in test suite: a commit carrying a tests-fail file fails
  printf '#!/bin/sh\n[ ! -f tests-fail ]\n' >"$g/dev/tests/run-all.sh"
  chmod +x "$g/dev/install.sh" "$g/dev/tests/run-all.sh"
  echo 1 >"$g/dev/f"
  git -C "$g/dev" add -A; git -C "$g/dev" commit -qm first
  git -C "$g/dev" push -q origin master
  git clone -q -b master "$g/origin.git" "$g/checkout"
  CO="$g/checkout"
  (cd "$CO" && TEST_ST="$ST" ./install.sh)
  : >"$ST/installs"
}
push() {   # push <subject> [add|rm <file>]
  local d="$ST/git/dev"
  echo "$1" >>"$d/f"
  case "${2:-}" in add) touch "$d/$3"; git -C "$d" add "$3" ;; rm) git -C "$d" rm -q "$3" ;; esac
  git -C "$d" commit -qam "$1"
  git -C "$d" push -q origin master
  git -C "$d" rev-parse --short HEAD
}
update() {   # runs the updater the way the unit does; prints its exit code
  TEST_ST="$ST" AGENT_SESSION_DIR="$ST" AGENT_UPDATE_HEALTH_WAIT=3 bash "$UPDATER"
  echo $?
}
field() { jget "$(cat "$ST/update.json")" "['$1']"; }
head_of() { git -C "$CO" rev-parse --short HEAD; }

echo "=== a new commit: fast-forward, test, install, verify"
setup
C1=$(head_of)
C2=$(push "second")
ok "$(update)" "0" "exit 0"
ok "$(field state)" "ok" "update.json says ok"
ok "$(field from)/$(field to)" "$C1/$C2" "from the installed commit to the new one"
ok "$(head_of)" "$C2" "the checkout is at the new commit"
ok "$(cat "$ST/installs")" "$C2" "installed once, the new commit"
has "$(cat "$ST/update.log")" "agent-update" "the run is logged"

echo "=== nothing new: says so and installs nothing"
: >"$ST/installs"
ok "$(update)" "0" "exit 0"
has "$(field message)" "already up to date" "already up to date"
ok "$(cat "$ST/installs")" "" "nothing installed"

echo "=== failing tests: nothing is installed, the checkout goes back"
C3=$(push "breaks the tests" add tests-fail)
ok "$(update)" "1" "exit 1"
ok "$(field state)/$(field stage)" "failed/test" "failed at the test stage"
ok "$(head_of)" "$C2" "the checkout is back where it was"
ok "$(cat "$ST/installs")" "" "nothing was installed"
has "$(field message)" "$C2 is still running" "and says what is still running"

echo "=== a build that never comes up is rolled back"
C4=$(push "fixes the tests, but will not start" rm tests-fail)
echo "$C4" >"$ST/broken"
ok "$(update)" "1" "exit 1"
ok "$(field state)" "rolled_back" "rolled back"
ok "$(head_of)" "$C2" "the checkout is back at the last good commit"
ok "$(tr '\n' ' ' <"$ST/installs")" "$C4 $C2 " "installed the new build, then the old one again"
ok "$(jget "$(cat "$ST/build.json")" "['commit']")" "$C2" "and the old build is what is installed"
rm -f "$ST/broken"; : >"$ST/installs"

echo "=== a pull without an install: the update installs it, rollback knows the difference"
git -C "$CO" merge -q --ff-only "origin/master"     # the user pulled, never installed
ok "$(head_of)" "$C4" "checkout is ahead of what is installed ($C2)"
echo "$C4" >"$ST/broken"
ok "$(update)" "1" "the new build fails again"
ok "$(tail -1 "$ST/installs")" "$C2" "and the rollback reinstalls the INSTALLED build, not HEAD"
rm -f "$ST/broken"; : >"$ST/installs"

echo "=== refusals leave everything as it was"
setup
C1=$(head_of)
push "new" >/dev/null
echo edit >>"$CO/f"
ok "$(update)" "2" "uncommitted changes: refused (exit 2)"
ok "$(field state)" "refused" "update.json says refused"
has "$(field message)" "uncommitted" "and why"
ok "$(head_of)" "$C1" "the checkout did not move"
git -C "$CO" checkout -q -- f

git -C "$CO" checkout -q -b feature
ok "$(update)" "2" "another branch: refused"
has "$(field message)" "not 'master'" "and why"
git -C "$CO" checkout -q master

echo local >"$CO/g"; git -C "$CO" add g; git -C "$CO" commit -qm "local only"
ok "$(update)" "2" "diverged from origin: refused"
has "$(field message)" "diverged" "and why"
ok "$(cat "$ST/installs")" "" "nothing was ever installed"

echo "=== no checkout recorded"
reset_state
printf '{"commit":"unknown","repo":""}\n' >"$ST/build.json"
ok "$(update)" "2" "refused"
has "$(field message)" "no git checkout" "and why"

finish
