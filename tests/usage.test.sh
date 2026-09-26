#!/usr/bin/env bash
# §20 usage: GET /usage — provider-agnostic tokens/cost from the transcript,
# plus whatever balance the current provider's helper can report.
#
#     bash tests/usage.test.sh
#
source "$(cd "$(dirname "$0")" && pwd)/harness.sh"
harness_init "${TMPDIR:-/tmp}/wa-tests/usage" "${TEST_PORT:-8392}"
export AGENT_USAGE_REFRESH=1     # recompute immediately rather than every 30s

# A transcript as pi writes it: assistant messages carrying `usage`, with the
# model named on each one. This is what makes the totals provider-agnostic.
seed_usage_transcript() {   # seed_usage_transcript <file> <cost> <msgs>
  local f=$1 cost=$2 n=$3 now_ms
  now_ms=$(date +%s%3N)
  seed_session sessions "$f"
  local i=0
  while [ "$i" -lt "$n" ]; do
    printf '{"type": "message", "message": {"role": "assistant", "model": "fake-model", "timestamp": %s, "usage": {"input": 100, "output": 50, "cacheRead": 10, "cacheWrite": 0, "cost": {"total": %s}}}}\n' \
      "$now_ms" "$cost" >>"$ST/sessions/$f"
    i=$((i + 1))
  done
}

helper() {   # helper <file> <json-printf-args…>
  local f=$1; shift
  {
    echo '#!/bin/sh'
    printf 'echo %s\n' "'$*'"
  } >"$f"
  chmod +x "$f"
}

echo "=== the transcript totals are provider-agnostic (no helper involved)"
reset_state
seed_usage_transcript live.jsonl 0.01 3
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" start_daemon
sleep 1.5
U=$(api GET /usage)
ok "$(code GET /usage)" "200" "200 OK"
ok "$(jget "$U" "['session']['messages']")" "3" "counts the priced turns"
ok "$(jget "$U" "['session']['cost']")" "0.03" "sums cost.total"
ok "$(jget "$U" "['session']['input']")" "300" "sums input tokens"
ok "$(jget "$U" "['session']['cache_read']")" "30" "sums cached tokens"
ok "$(jget "$U" "['today']['messages']")" "3" "and splits out today"
ok "$(jget "$U" "['model']")" "fake-model" "names the live model"
ok "$(jget "$U" "['provider']")" "fake" "and the provider"
ok "$(jget "$U" "['balance']")" "" "no helper: no balance, and no invention"
stop_daemon

echo "=== an erroring helper degrades instead of lying"
reset_state
seed_usage_transcript live.jsonl 0.02 1
helper "$ST/bad-usage" '{"error": "http error (curl 22)"}'
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" \
  AGENT_USAGE_CMD="$ST/bad-usage" start_daemon
sleep 1.5
U=$(api GET /usage)
ok "$(jget "$U" "['balance']['ok']")" "False" "reports the failure"
has "$(jget "$U" "['balance']['err']")" "curl 22" "with the helper's reason"
ok "$(jget "$U" "['session']['cost']")" "0.02" "the local totals still work"
stop_daemon

echo "=== a provider helper in the live-stats shape"
reset_state
seed_usage_transcript live.jsonl 0.05 2
helper "$ST/ok-usage" '{"currency":"USD","total":"5.90","granted":"0.90","topped_up":"5.00","spent":12.34,"topup_total":50}'
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" \
  AGENT_USAGE_CMD="$ST/ok-usage" start_daemon
sleep 1.5
U=$(api GET /usage)
ok "$(jget "$U" "['balance']['ok']")" "True" "balance ok"
ok "$(jget "$U" "['balance']['total']")" "5.90" "decimal string passed through"
ok "$(jget "$U" "['balance']['currency']")" "USD" "with its currency"
ok "$(jget "$U" "['balance']['spent']")" "12.34" "spend since the top-up"
ok "$(jget "$U" "['balance']['cmd']")" "$ST/ok-usage" "and which helper answered"
stop_daemon

echo "=== AGENT_USAGE_CMD accepts arguments, and a failing helper is survivable"
reset_state
seed_usage_transcript live.jsonl 0.01 1
helper "$ST/args-usage" '{"currency":"EUR","total":"1.00"}'
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" \
  AGENT_USAGE_CMD="/bin/sh $ST/args-usage extra" start_daemon
sleep 1.5
U=$(api GET /usage)
ok "$(jget "$U" "['balance']['currency']")" "EUR" "ran the command with its argument"
stop_daemon

reset_state
seed_usage_transcript live.jsonl 0.01 1
FAKE_PI_SCENARIO=ok FAKE_PI_SESSION="$ST/sessions/live.jsonl" \
  AGENT_USAGE_CMD="/nonexistent/usage-helper" start_daemon
sleep 1.5
U=$(api GET /usage)
ok "$(jget "$U" "['balance']['ok']")" "False" "a missing binary is reported, not fatal"
ok "$(jget "$U" "['session']['messages']")" "1" "and the totals are unaffected"
has "$(api GET /state)" '"sessionFile"' "the daemon is still serving"
stop_daemon

finish
