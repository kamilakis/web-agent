# Resume a past session from the web dashboard — spec (not yet built)

Written 2026-09-25 for a later agent to implement. Read `docs/spec.md` §17.5–17.8
first: they describe the `/opensession` endpoint and the `active-session` record
that this builds on.

## 1. What works today

| Capability | Where | State |
|---|---|---|
| List sessions (Running / Previous / Archived) | `GET /sessions`, `renderSessions()` | ✅ |
| View a past transcript **read-only** | `GET /session?file=&dir=`, `openSession()` in `web/index.html` sets `viewing`, hides the composer, shows the "Viewing …" banner | ✅ |
| New session / Archive current + new | `POST /newsession`, `POST /archive` → `switch_to_new()` | ✅ |
| Rename the live session | `POST /sessionname` | ✅ |
| **Resume** an existing transcript | `POST /opensession {file, dir}` → `open_session()` | ⚠ **backend only**: no UI calls it (curl only) |
| Resume survives a daemon restart | `$AGENT_SESSION_DIR/active-session` + `start_pi --session <path>` | ✅ (§17.7) |

**Answer to "can I restore an archived session?"** Only with curl today:

```sh
curl -X POST http://127.0.0.1:8383/opensession \
     -d '{"file":"2026-09-19T09-50-46-734Z_siri-agent.jsonl","dir":"archive"}'
```

In the dashboard, clicking an archived or previous session only **views** it.
The job is to add the UI **and** fix the backend bugs below, several of which
only show up once resuming is a one-tap action.

Naming: the UI says **Resume**, not "restore". The endpoint stays
`/opensession`; do not rename it.

## 2. How pi behaves on `switch_session` (verified in pi 0.87.1 source)

Source: `~/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/`.

1. `core/agent-session-runtime.js switchSession()` → `SessionManager.open(path)`
   **with no sessionDir**, so pi's session dir becomes **the file's parent
   directory**. Resuming a file in `archive/` makes `archive/` pi's session dir.
2. `assertSessionCwdExists()` throws if the header's `cwd` no longer exists.
   Every current transcript has `cwd: /home/nuc/assistant`, so this is only a
   future risk, but the error must reach the user as an error, not as a 500
   with no explanation.
3. `_setSessionFile()`: an **empty** file is silently turned into a *new*
   session with a random id and rewritten. A non-empty file that does not
   parse throws. Old-version files are migrated and **rewritten in place**
   (`_rewriteFile`, not atomic). All current files are version 3.
4. **The model is NOT restored from the transcript.** `main.js createRuntime`
   passes `sessionOptions.model` (from the daemon's `--provider/--model` CLI
   flags) into every runtime it creates, including the one a switch creates. The
   sdk only restores a session's model when `options.model` is unset. So after
   **any** switch (open, new or archive), pi is back on `AGENT_MODEL`, whatever
   the user picked in the dropdown and whatever the vision auto-switch set.
   *Verify this live* (step 0 of the build) by comparing `GET /state` `.model`
   before and after a switch while on a non-default model.
5. The thinking level **is** restored from the transcript's
   `thinking_level_change` entries.
6. Old images in the history are safe on a text-only model:
   `pi-ai transform-messages.js` replaces them with
   `"(image omitted: model does not support images)"`.

## 3. Bugs to fix (found reading the code; each needs a test)

### B1 — daemon: stale `model_input` after any switch (pre-existing, severe with resume)
`self.model_input` caches whether the current model accepts images. Per §2.4, a
switch silently puts pi back on `AGENT_MODEL`. If the vision auto-switch had run
before the switch, the cache still says images are OK, so the next photo goes to
a text-only model. The daemon does not auto-switch, and pi replaces the image
with "(image omitted…)". Fix: `self.model_input = None` in `_reset_run_state()`
(or right after every successful `switch_session`), so `_model_accepts_images()`
re-queries.

### B2 — UI: model dropdown not refreshed on `session_switched` (pre-existing)
`onEvent` → `session_switched` calls `refreshHeader()`, which updates only the
name. The dropdown keeps showing the old model. Fix: `refreshHeader()` also
re-selects `modelSel` from `st.model` (same `provider|id` key as `init()`).

### B3 — daemon: "already open" check runs AFTER aborting the run
`_open_session()` calls `_abort_and_settle()` first and then checks
`old_file == path`. Opening the live session therefore kills its running reply
and then returns an error. Fix: do the get_state and same-file comparison
**before** the abort.

### B4 — daemon: no validity check on the resume target
`/opensession` checks only `isfile`. Per §2.3 an empty file becomes a new random
id session (it drops out of the `*_siri-agent.jsonl` fallback and loses its
identity), and a non-JSON file makes pi throw. Fix: in the handler, require
`_valid_session_file(target)` → otherwise 422 `{"error":"not a resumable
session file"}`.

### B5 — resuming from `archive/` leaves the live session in `archive/`
Consequences, today:
- `renderSessions()` shows it **twice**: under *Running* (`s.active`) **and**
  under *Archived* (`arch` does not exclude `active`).
- pi's session dir is now `archive/` (§2.1).
- "Archive" on it later does `os.replace(x, x)`, a silent no-op, and reports
  success.
- `_newest_session_file()` (restart fallback) only scans `sessions/`.

**Decision: resuming an archived session un-archives it.** Before
`switch_session`, `os.replace(archive/X, sessions/X)` and resume the new path.
It comes back as a normal live session, and archiving it again later works.
Details:
- Collision: if `sessions/X` exists, return 409 `{"error":"a session with that
  file name already exists in sessions/"}`. Do not overwrite.
- Rollback: if `switch_session` fails or is cancelled, move it back to
  `archive/` (log if that also fails; the file is never deleted).
- Do the move **after** the B3 same-file check and the abort, inside the
  `switching` guard, so no prompt can land in between.
- Response gains `"unarchived": true` and `newFile` = the `sessions/` path;
  `record_active_session()` records the `sessions/` path.
- Also make `renderSessions()` defensive: `arch = …filter(s => s.dir ===
  'archive' && !s.active)`.

### B6 — `/sessions` flags "active" by basename only
`info["active"] = (n == active)` ignores the dir, so a basename that exists in
both dirs gets flagged twice. B5's 409 prevents that case, but compare
`realpath`s anyway: it costs nothing.

### B7 — UI: resuming the file another tab is *viewing*
Tab A views X read-only while tab B resumes X. Tab A's `session_switched`
handler skips `refreshLive()` because `viewing` is set, so A stays in read-only
mode on what is now the live session. Fix: in the handler, if
`viewing && ev.newFile` ends with `'/' + viewing.file`, call `returnToLive()`.
(After un-archiving, `viewing.dir` is stale but the basename still matches.)

### B8 — interrupted Siri/Matrix run on switch (pre-existing, becomes likelier)
`_abort_and_settle()` + `_reset_run_state()` clear `busy`, so the later
`agent_settled` finds `busy == False` and `settle()` never runs. A Siri caller
polling for `results/<pid>.result` gets nothing and times out. A Matrix prompt
gets no reply at all. Fix: before `_reset_run_state()` in both switch paths,
capture `current_source/current_id/current_prompt`. If the source was siri or
matrix, deliver `"⚠ Interrupted: the session was switched from the web
dashboard."` the way `on_prompt_rejected` delivers a give-up (result file or
`post_matrix`). Queued FIFO prompts (`self.q`) are not dropped. They run in the
resumed session, which is correct, but the confirm dialog must say so (§4).

### B9 — huge transcripts
`archive/2026-09-10…` is 3 MB with 16 images, and pi rewrites old-version files
non-atomically (§2.3). Resuming one on a small-context model may overflow on
the first prompt. Do not build anything for this up front. Test it (T9) and
record what pi does: auto-compaction, an error bubble (already surfaced by §17),
or a silent failure. File a follow-up only if it is not the first two.

## 4. UI design (respect spec.md §5.6 styling; do not restyle)

- **Banner button.** While `viewing`, the banner gets a second button next to
  "← Return to live": **"▶ Resume this session"**. This is the only entry
  point, so the user always sees what they are resuming before they commit.
  Sidebar clicks keep their current meaning (view).
- **Confirm** (`confirm()`, like `doSwitch`):
  `Resume "<title>"? It becomes the live session for web, Siri and Matrix.`
  + `\nThe running reply will be stopped.` when `working`
  + `\nIt will move out of Archived.` when `viewing.dir === 'archive'`.
- **On click:** disable the button, then `POST /opensession {file, dir}`. On
  success set `viewing = null`, hide the banner, show the composer, clear
  `mine`, `resetStream()`, `setStatus(false)`, `await loadSessions()`,
  `refreshHeader()` (now with B2), `refreshLive()`. On error: `sbMsg(error)`,
  re-enable, stay in view mode. The `session_switched` SSE event also arrives.
  Make the handler idempotent so the double refresh is harmless.
- **Old daemon:** a 404 from `/opensession` → `sbMsg('resume needs a daemon
  restart')`, the same pattern as the sessions-list fallback.
- **Header, no new element:** the name comes from the transcript's own
  `session_info` (the daemon does not pass `-n` on resume, §17.7).
- Bump `UI_VERSION`.

## 5. Build order

0. **Rebuild the test harness and commit it this time** under `tests/`. The
   §17.4/17.8 fake-pi harness and `ui.test.js` were never checked in: the repo
   has no tests. The fake pi must support `get_state` (sessionFile,
   sessionName, model, messageCount), `switch_session` (with a switch to
   *fail*/*cancel* mode for rollback tests), `set_model`, `abort`,
   `clear_queue`, `get_messages`, and emit `agent_start`/`agent_settled`. Run
   the daemon with `AGENT_SESSION_DIR=<tmp>`, `AGENT_WEB_PORT=<free>`,
   `AGENT_QUIET_MATRIX=1`, `PATH=<fake-pi dir>:$PATH`.
   Also check §2.4 live against real pi and note the result in this file.
1. Daemon: B3, B4, B1, B6, then B5 (un-archive + rollback), then B8.
2. UI: banner button + resume flow, B2, B7, the defensive `arch` filter.
3. Docs: README endpoint line (`/opensession` un-archives), and a
   `docs/spec.md` §18 entry pointing here with the test results.
4. Deploy: `install.sh` copies `web/index.html` to `$STATE/web/`, then
   `systemctl --user restart agent-session`. A restart resumes the active
   session (§17.7), so nothing is lost.

## 6. Test plan

Hermetic (fake pi) unless marked **live**.

| # | Case | Expected |
|---|---|---|
| T1 | resume a `sessions/` file while idle | 200, `/state` sessionFile = it, `active-session` = it, SSE `session_switched` |
| T2 | resume an `archive/` file | file now in `sessions/`, gone from `archive/`, `unarchived:true`, record = sessions path, `/sessions` lists it once, as active |
| T3 | T2 with `switch_session` failing / cancelled | file back in `archive/`, record unchanged, error returned |
| T4 | T2 with a same-named file already in `sessions/` | 409, nothing moved, no abort sent |
| T5 | resume the live session while a run is active | error "already open", **no** `abort` sent to pi (B3) |
| T6 | empty file / garbage first line | 422, pi never receives `switch_session` (B4) |
| T7 | switch while a vision-model auto-switch is cached | `model_input` re-queried; next image prompt triggers the auto-switch again (B1) |
| T8 | switch during a Siri run (pid set) | `results/<pid>.result` holds the interrupted message; queued FIFO prompt then runs in the new session (B8) |
| T9 | **live**: resume `archive/2026-09-10T16-18-25-748Z_siri-agent.jsonl` (3 MB, 16 images) on the default model, send "summarise where we left off" | a reply or a visible error bubble, never silence; note what pi did (B9) |
| T10 | restart the daemon after T2 | comes back on the resumed file (from `sessions/`) |
| T11 | UI stub DOM: banner button → confirm → POST → composer visible, banner hidden, `viewing` null, dropdown = `/state` model (B2) | pass |
| T12 | UI: two tabs, A viewing X, B resumes X | A leaves view mode and renders live (B7) |
| T13 | traversal / bad dir / non-jsonl / missing (existing §17.6 cases) | still 400/404 |
| T14 | regressions: §17.4 error surfacing, §17.8 restart suite, renderer | all green |

## 7. Out of scope

- Forking or branching from a point in a past session (pi has `fork`/`clone`;
  a later feature).
- Deleting sessions.
- Resuming *from the sidebar* without viewing first.
- Keeping the user's model choice across switches (§2.4). B1/B2 only make the
  reset **visible and correct**. Re-applying the chosen model after a switch
  (`model_set` after `switch_session`) is a one-line follow-up if the owner
  wants it. Ask before adding it.
