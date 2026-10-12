#!/usr/bin/env bash
# §25 the model dropdown follows the agent, wherever the switch happens.
#
# Before this, the page learned the model only on load and on session switch,
# so a switch made from anywhere else — curl, the photo auto-switch, the
# AGENT_MODEL a restart lands on — left every open tab's dropdown on the model
# the agent stopped being.
#
#     bash tests/model-switch.test.sh
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/model-switch" "${TEST_PORT:-8396}"

echo "=== a switch is applied, and every open dashboard is told"
reset_state
start_daemon
ok "$(state_field "['model']['id']")" "fake-model" "starts on the fake model"
sse_start
ok "$(code POST /model '{"provider":"hetzner","modelId":"Qwen/Qwen3.8-27B"}')" \
   "200" "the switch is accepted"
sleep 0.5
ok "$(state_field "['model']['id']")" "Qwen/Qwen3.8-27B" "and the state follows"
has "$(cat "$ST/sse")" '"type": "model_changed"' "open dashboards were told"
has "$(cat "$ST/sse")" '"id": "Qwen/Qwen3.8-27B"' "and which model to show"
has "$(cat "$ST/sse")" '"provider": "hetzner"' "under which provider"
sse_stop

echo "=== and switching back is just another event"
sse_start
ok "$(code POST /model '{"provider":"deepseek","modelId":"deepseek-flash"}')" "200" "accepted"
sleep 0.5
ok "$(state_field "['model']['id']")" "deepseek-flash" "the state is back"
has "$(cat "$ST/sse")" '"id": "deepseek-flash"' "and the dropdown is told"
sse_stop
stop_daemon

finish
