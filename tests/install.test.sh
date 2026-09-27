#!/usr/bin/env bash
# install.sh restarts what it installed (or says it did not), and works from
# any directory. systemctl is a stub: nothing here touches real units.
#
#     bash tests/install.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/install" "${TEST_PORT:-8388}"

stub_path() {
  mkdir -p "$ST/stub"
  printf '#!/bin/sh\necho "$*" >>"%s/systemctl.log"\n' "$ST" >"$ST/stub/systemctl"
  chmod +x "$ST/stub/systemctl"
  echo "$ST/stub:$PATH"
}

echo "=== a re-install restarts the services, so the new build is what runs"
reset_state
P=$(stub_path)
( cd / && PATH="$P" PREFIX="$ST/home" bash "$REPO/install.sh" >"$ST/install.out" 2>&1 )
ok "$?" "0" "runs from outside the checkout"
ok "$(test -x "$ST/home/.local/bin/agent-session-daemon" && echo yes)" "yes" "installed the daemon"
has "$(cat "$ST/systemctl.log")" "--user restart agent-session.service" "restarted it"
has "$(cat "$ST/home/.local/share/agent-session/build.json")" '"commit"' "recorded the build"

echo "=== NO_RESTART=1 leaves the running daemon alone and says so"
reset_state
P=$(stub_path)
PATH="$P" PREFIX="$ST/home" NO_RESTART=1 bash "$REPO/install.sh" >"$ST/install.out" 2>&1
hasnt "$(cat "$ST/systemctl.log")" "restart" "no restart"
has "$(cat "$ST/install.out")" "NOT restarted" "and it says the old build is still running"

finish
