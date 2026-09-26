#!/usr/bin/env bash
# Run every web-agent suite. Each one starts its own throwaway daemon on its own
# port against the fake pi; none of them can touch the live agent.
#
#     bash tests/run-all.sh
#
set -uo pipefail
cd "$(dirname "$0")"
fails=0
run() {
  echo
  echo "########## $* ##########"
  "$@" || { echo "  ^^ SUITE FAILED"; fails=$((fails + 1)); }
}

run node describeTool.test.js
run node toolRows.test.js
run node ui.test.js
run bash opensession.test.sh
run bash delete.test.sh
run bash version.test.sh
run bash service.test.sh
run bash usage.test.sh
run bash errors.test.sh
run bash resume.test.sh

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL SUITES PASS"
else
  echo "$fails SUITE(S) FAILED"
fi
exit "$fails"
