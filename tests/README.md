# Tests

```sh
bash tests/run-all.sh          # everything
node tests/ui.test.js          # one suite
```

No dependencies. Everything runs offline.

## The rule these tests follow

**They never touch the live agent.** A suite starts a throwaway daemon with its
own `AGENT_SESSION_DIR`, its own port, `AGENT_WEB_HOST=127.0.0.1`, and
`tests/fakebin` first on `PATH` so `pi` is the fake. The real daemon on :8383 —
its state, its session, its FIFO — is not reachable from here.

| File | What it covers |
|---|---|
| `harness.sh` | shared plumbing: assertions, JSON helpers, daemon start/stop, SSE capture, fixtures |
| `fakebin/pi` | fake `pi --mode rpc`: scripted runs, switch outcomes, and a log of every command it received |
| `describeTool.test.js` | §8.3 tool descriptions — pure function, pulled out of `web/index.html` |
| `toolRows.test.js` | §8 tool rows against a stub DOM: parallel calls, errors, live vs reloaded |
| `ui.test.js` | the whole page under a stub DOM: §17.4 error surfacing, Part A banner/resume (T11/T12) |
| `opensession.test.sh` | Part A against the daemon: T1–T8, T13, B6 |
| `errors.test.sh` | §17.4 regression: failed runs are surfaced, Siri gets a spoken failure |
| `resume.test.sh` | §17.7 / T10: restart resumes the recorded transcript |

## Fake pi controls

Set these in the environment before `start_daemon`:

| Var | Values | Meaning |
|---|---|---|
| `FAKE_PI_SCENARIO` | `ok` `error` `errorbare` `retry` `hang` | what a prompt does; `hang` stays in flight until aborted |
| `FAKE_PI_SWITCH` | `ok` `fail` `cancel` `timeout` | how `switch_session` replies |
| `FAKE_PI_ABORT` | `settle` `silent` | whether an abort ends the run (B8 needs `silent`) |
| `FAKE_PI_MODEL_INPUT` | JSON list | the `input` kinds `get_state` reports |
| `FAKE_PI_MODEL_AFTER_SWITCH` | JSON `{id,input}` | models §2.4's silent model revert on switch |
| `FAKE_PI_MESSAGES` | int | `messageCount`, which `/archive` checks |

Introspection: `pi_saw <type>`, `pi_count <type>`, `pi_last_switch` — the fake
records everything the daemon sent, so a test can assert what did **not** happen
(no abort before the "already open" check, no `switch_session` for a bad target).

## Known gaps

- The suites that were never checked in before (`ui.test.js`, the fake pi) live
  here now; `docs/spec.md` §17.4/§17.8 record the runs that produced them.
- No browser: `ui.test.js` drives a stub DOM, so CSS (the tool-row dot colour on
  iOS, `#banner` layout) is not covered — that still needs an eyeball.
- Nothing here runs against real `pi`; §2.4's model-revert behaviour was checked
  by hand and is noted in `docs/spec.md` §18.
