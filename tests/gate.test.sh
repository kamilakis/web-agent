#!/usr/bin/env bash
# §24 the approval-gate on/off switch.
#
# The switch is a file ($STATE/gate.json) rather than daemon state, because two
# processes need it: the approval-gate pi extension enforces it, and this daemon
# draws it as a switch on the dashboard. These tests cover the daemon's half —
# the endpoint, persistence across a restart, the broadcast, and above all the
# direction that matters: NOTHING except an explicit {"enabled": false} may read
# as "off", because "off" means an unattended agent stops asking.
#
#     bash tests/gate.test.sh
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/gate" "${TEST_PORT:-8395}"
export AGENT_JANITOR_INTERVAL=1     # so the file-watch test does not wait 15s

echo "=== a fresh state dir is armed (there is no file at all)"
reset_state
start_daemon
ok "$(code GET /gate)" "200" "GET /gate answers"
ok "$(jget "$(api GET /gate)" "['enabled']")" "True" "defaults to armed"
ok "$([ -f "$ST/gate.json" ] && echo yes || echo no)" "no" \
   "asking did not create a file"

echo "=== moving the switch writes the file and tells every dashboard"
sse_start
ok "$(code POST /gate '{"enabled":false}')" "200" "POST /gate answers"
sleep 0.5
ok "$(jget "$(api GET /gate)" "['enabled']")" "False" "reads back as off"
ok "$(jget "$(api GET /gate)" "['source']")" "dashboard" "and records who moved it"
ok "$(jget "$(api GET /gate)" "['at']" | grep -qE '^[0-9]+\.' && echo stamp || echo none)" \
   "stamp" "and when"
ok "$(python3 -c "import json;print(json.load(open('$ST/gate.json'))['enabled'])")" \
   "False" "the file on disk says off"
has "$(cat "$ST/sse")" '"type": "gate"' "every open dashboard was told"
has "$(cat "$ST/sse")" '"enabled": false' "and what to draw"
ok "$([ -f "$ST/gate.json.tmp" ] && echo left || echo clean)" "clean" \
   "written atomically (no .tmp left behind)"
sse_stop

echo "=== it survives a restart — the whole reason it is a file"
stop_daemon
start_daemon
ok "$(jget "$(api GET /gate)" "['enabled']")" "False" "still off after the daemon restarts"

echo "=== and back on again"
sse_start
ok "$(code POST /gate '{"enabled":true}')" "200" "POST /gate answers"
sleep 0.5
ok "$(jget "$(api GET /gate)" "['enabled']")" "True" "reads back as armed"
has "$(cat "$ST/sse")" '"enabled": true' "dashboards were told to re-arm"
sse_stop

echo "=== toggle mode flips from wherever it is"
api POST /gate '{"toggle":true}' >/dev/null
ok "$(jget "$(api GET /gate)" "['enabled']")" "False" "toggle from armed lands disarmed"
api POST /gate '{"toggle":true}' >/dev/null
ok "$(jget "$(api GET /gate)" "['enabled']")" "True" "toggle from disarmed lands armed"

echo "=== a request that says nothing is refused, not guessed"
ok "$(code POST /gate '{}')" "400" "neither enabled nor toggle is a 400"
ok "$(code POST /gate '')" "400" "an empty body too"
ok "$(jget "$(api GET /gate)" "['enabled']")" "True" "and it left the switch alone"

echo "=== FAIL SAFE: only an explicit false may disarm it"
for bad in '' '{"enabled": tru' 'not json at all' '{}' '{"enabled": "false"}' \
           '{"enabled": null}' '{"enabled": 0}' '[]' '{"enabled": falsee}'; do
  printf '%s' "$bad" >"$ST/gate.json"
  ok "$(jget "$(api GET /gate)" "['enabled']")" "True" \
     "armed for: ${bad:-(empty file)}"
done
printf '{"enabled": false}\n' >"$ST/gate.json"
ok "$(jget "$(api GET /gate)" "['enabled']")" "False" \
   "but a real false is still honoured"

echo "=== a switch moved by /gate reaches the dashboards too"
# The extension writes the same file. Without the janitor watching it, the page
# would sit showing "on" after someone typed /gate off into the conversation.
# Establish a known position first, so the change below is a real change: the
# janitor polls, and a write to a value it already believes would prove nothing.
api POST /gate '{"enabled":false}' >/dev/null
sleep 0.3
sse_start
printf '{"enabled": true, "source": "command"}\n' >"$ST/gate.json"
sleep 3
has "$(cat "$ST/sse")" '"type": "gate"' "the change was noticed and broadcast"
has "$(cat "$ST/sse")" '"source": "command"' "and attributed to the command"
sse_stop

echo "=== an unchanged switch broadcasts nothing (a poll is not an event)"
sse_start
sleep 3
hasnt "$(cat "$ST/sse")" '"type": "gate"' "no repeat broadcast"
sse_stop
stop_daemon

echo "=== the switch obeys the dashboard token like everything else"
reset_state
export AGENT_WEB_TOKEN=sekret
start_daemon
ok "$(curl -s -o /dev/null -w '%{http_code}' -m 25 "http://127.0.0.1:$PORT/gate")" \
   "401" "GET /gate needs the token"
ok "$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST \
       "http://127.0.0.1:$PORT/gate" -H 'Content-Type: application/json' \
       -d '{"enabled":false}')" "401" "POST /gate needs the token"
ok "$(jget "$(curl -s -m 25 "http://127.0.0.1:$PORT/gate?token=sekret")" "['enabled']")" \
   "True" "the unauthorized POST did not move the gate"
ok "$(curl -s -o /dev/null -w '%{http_code}' -m 25 \
       "http://127.0.0.1:$PORT/gate?token=sekret")" "200" "and ?token= still works"
stop_daemon
unset AGENT_WEB_TOKEN

finish
