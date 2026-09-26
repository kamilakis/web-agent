#!/usr/bin/env bash
# §21 extension dialogs reach the dashboard, and the answer goes back to pi.
#
# Before this, the daemon answered every select/confirm/input/editor request
# with {"cancelled": true} the instant it arrived — so an approval question was
# never shown and every gated tool call was denied without the user seeing it.
#
#     bash tests/ui-relay.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/ui-relay" "${TEST_PORT:-8391}"
export AGENT_UI_TIMEOUT="${AGENT_UI_TIMEOUT:-6}"
export AGENT_UI_NOUI_GRACE=3

# What the daemon sent back to pi, as JSON objects.
pi_responses() { python3 -c "
import json
for line in open('$ST/pi-cmds'):
    line = line.strip()
    if not line:
        continue
    try:
        c = json.loads(line)
    except Exception:
        continue
    if c.get('type') == 'extension_ui_response':
        print(json.dumps(c, sort_keys=True))" 2>/dev/null; }

ask() {   # ask <method> <extra json…> — make the fake pi raise a dialog
  printf '%s\n' "$@" >>"$ST/ask"
}

echo "=== a select reaches the dashboard and the picked option goes back"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"select","title":"⚠️  Run shell command?","options":["1) Allow once","2) Allow for this session","3) Deny","4) Deny, but instead…"]}' start_daemon
sse_start
api POST /prompt '{"message":"do a thing"}' >/dev/null
sleep 1.5
ok "$(grep -c '"type": "ui_request"' "$ST/sse")" "1" "the question was broadcast"
has "$(cat "$ST/sse")" 'Run shell command' "with its title"
has "$(cat "$ST/sse")" 'Allow for this session' "and its options"
ID=$(python3 -c "
import json
for line in open('$ST/sse'):
    line = line.strip()
    if not line.startswith('data:'): continue
    try: e = json.loads(line[5:])
    except Exception: continue
    if e.get('type') == 'ui_request': print(e['id']); break" 2>/dev/null)
ok "${ID:-none}" "ui-1" "carries pi's id"
ok "$(code POST /ui_response "{\"id\":\"$ID\",\"value\":\"1) Allow once\"}")" "200" "the answer is accepted"
sleep 0.5
has "$(pi_responses)" '"value": "1) Allow once"' "and was forwarded to pi"
hasnt "$(pi_responses)" '"cancelled": true' "not a cancellation"
sse_stop
stop_daemon

echo "=== confirm and input use their own response shapes"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"confirm","title":"⚠️  Really?"}' start_daemon
sse_start
api POST /prompt '{"message":"x"}' >/dev/null
sleep 1.2
ID=$(api GET /ui | python3 -c 'import json,sys; p=json.load(sys.stdin)["pending"]; print(p[0]["id"] if p else "")')
ok "$(test -n "$ID" && echo yes || echo no)" "yes" "GET /ui lists the pending question (reload case)"
api POST /ui_response "{\"id\":\"$ID\",\"confirmed\":true}" >/dev/null
sleep 0.5
has "$(pi_responses)" '"confirmed": true' "confirm answers with a boolean"
sse_stop
stop_daemon

reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"input","title":"Instead, I should…","placeholder":"e.g. use the dashboard"}' start_daemon
sse_start
api POST /prompt '{"message":"x"}' >/dev/null
sleep 1.2
ID=$(api GET /ui | python3 -c 'import json,sys; p=json.load(sys.stdin)["pending"]; print(p[0]["id"] if p else "")')
api POST /ui_response "{\"id\":\"$ID\",\"value\":\"ask me first\"}" >/dev/null
sleep 0.5
has "$(pi_responses)" '"value": "ask me first"' "input answers with text"
sse_stop
stop_daemon

echo "=== cancel, and a second answer is refused"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"select","title":"⚠️  Pick","options":["a","b"]}' start_daemon
sse_start
api POST /prompt '{"message":"x"}' >/dev/null
sleep 1.2
ID=$(api GET /ui | python3 -c 'import json,sys; p=json.load(sys.stdin)["pending"]; print(p[0]["id"] if p else "")')
ok "$(code POST /ui_response "{\"id\":\"$ID\",\"cancelled\":true}")" "200" "cancelling is accepted"
sleep 0.4
ok "$(code POST /ui_response "{\"id\":\"$ID\",\"value\":\"a\"}")" "409" "answering again is refused"
has "$(pi_responses)" '"cancelled": true' "pi was told it was cancelled"
sse_stop
stop_daemon

echo "=== nobody connected: the question is closed rather than hanging the run"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"select","title":"⚠️  Anybody?","options":["a"]}' start_daemon
api POST /prompt '{"message":"x"}' >/dev/null
sleep 5                      # AGENT_UI_NOUI_GRACE=3, so this has passed
has "$(pi_responses)" '"cancelled": true' "cancelled after the no-UI grace"
has "$(cat "$ST/out")" "no dashboard is connected" "with the reason in the log"
stop_daemon

echo "=== an answer that never comes times out instead of blocking forever"
reset_state
FAKE_PI_SCENARIO=hang FAKE_PI_UI='{"method":"select","title":"⚠️  Waiting","options":["a"]}' start_daemon
sse_start                    # a client IS connected, so only the deadline applies
api POST /prompt '{"message":"x"}' >/dev/null
sleep 8                      # AGENT_UI_TIMEOUT=6
has "$(cat "$ST/out")" "nobody answered in time" "the watchdog closed it"
has "$(pi_responses)" '"cancelled": true' "and pi was released"
sse_stop
stop_daemon

finish
