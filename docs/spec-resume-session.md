# Dashboard sessions & tool rows — spec (not yet built)

Three features, one file: **Part A** resume a past session (§1–7), **Part B**
descriptive tool rows (§8), **Part C** delete a session (§9). They share
`web/index.html` and the fake-pi harness (§5 step 0), so build A → C → B, or B
first if tool rows matter more. Each part stands alone.

## Part A — Resume a past session

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

---

## Part B — Descriptive tool rows

> **Built 2026-09-25 (Tier 1 only)** — see `docs/spec.md` §18.1 for what landed
> and the test results. Tier 2 (model-written bash descriptions) and §8.4's
> iPhone-Safari screenshot check are still open.

### 8.1 What it looks like now (screenshots from 2026-09-25, iPhone Safari)

- `docs/img-tool-rows-live.png`: **live stream.** Every row shows only the raw
  tool name (`bash`, `mcp__memos__search_memos`). There is no argument and no
  description, and some rows keep pulsing after they finished.
- `docs/img-tool-rows-after-refresh.png`: **the same turn after a reload.**
  Now rows show a one-line argument (`fleet`, `2Lg84ji2mv…`), and every result
  is a **separate `result` row**, detached from its call.

The transcript (`sessions/2026-09-25T11-40-08-282Z_siri-agent.jsonl`, "How many
hosts are with ssh access") confirms the doubled rows are **parallel tool
calls**: one assistant message carrying 2–3 `toolCall` blocks. They are not
duplicates. The screenshots do show these rendering bugs:

| # | Bug | Cause (`web/index.html`) |
|---|---|---|
| L1 | Live rows have no argument or detail | `toolcall_start` → `toolRow(d.toolName, null)`. Nothing fills it in later, although `toolcall_end` carries `toolCall.arguments` and `tool_execution_start` carries `args` |
| L2 | With parallel calls, earlier rows pulse forever and outputs go to the wrong row | one `curTool` pointer. `tool_execution_update/_end` always hit the **last** row created. Key rows by `toolCallId` instead (`toolcall_end.toolCall.id`, `tool_execution_*.toolCallId`) |
| L3 | Live and reloaded views differ | live writes the result **into** the call row's `.out` (replacing args). The snapshot renders `toolResult` as a separate `toolRow('result', …)` appended to `logEl`, so it lands outside the assistant message |
| L4 | Status dot is a blue square on iOS, not a green/red/orange dot | `content:"⏺"` renders as an emoji on iOS, which ignores `color`. Use `"⏺︎"`, or better a CSS circle (`width/height:7px; border-radius:50%; background:currentColor`) |
| L5 | Large vertical gaps | each tool step is its own `.msg.assistant` plus `details.tool` margins 10/12px. Tighten margins for consecutive tool rows |
| L6 | Reloaded history can't pair results with calls | `session_messages()` (daemon, past sessions) keeps only `role` + `content` and drops `toolCallId`, `toolName`, `isError`. Live `/messages` passes them through. Keep them in both |

### 8.2 Target

**One row per tool call, in the same form live and after reload:**

```
● Searching memos for “ssh access”                 mcp memos ›
   ▸ expanded:
     call    {"query": "ssh access", "page_size": 30}
     result  Search results for "ssh access": 4 memos…   (capped as today)
```

- **Summary line:** a plain-language description in the body font (not mono).
  The tool name is a small dim tag on the right. A running row shows the
  description with the pulsing dot. An error row is red with the first line of
  the error.
- **Expanded:** the exact call (the command for bash, JSON args otherwise)
  **and** the result, labelled. This is the "toggle to see the actual command"
  the owner asked to keep.
- The result is attached to its call by `toolCallId`: live via
  `tool_execution_end`, reloaded via the `toolResult` message's `toolCallId`.
  There are no standalone `result` rows. Fall back to a standalone row only
  when no call with that id is on screen (old snapshot, or truncated by
  `MSG_SNAPSHOT=50`).

### 8.3 Where descriptions come from

**Tier 1 (build this): a deterministic client-side `describeTool(name, args)`.**
It is a pure function in `index.html`, unit-tested with node, costs nothing,
and works on every old transcript.

| tool | description |
|---|---|
| `bash` | `args.description` if present (Tier 2); else a short form of the command: strip a leading `cd … &&`, take the first command, e.g. `Running ls /home/nuc/assistant`, ellipsised at ~60 chars |
| `read` / `write` / `edit` | `Reading notes.md` / `Writing …` / `Editing …` (basename; full path in the expanded view) |
| `grep` | `Searching files for “pattern”` |
| `find` | `Finding files named “pattern”` |
| `ls` | `Listing <dir>` |
| `mcp__memos__search_memos` | `Searching memos for “<query>”` |
| `mcp__memos__get_memo` | `Opening memo <first 8 of id>…` |
| other `mcp__<server>__<tool>` | `<Tool words> (<server>)` + first string arg, e.g. `List labels (gmail): inbox` |
| anything else | tool name with `_` → space, sentence case, + `argPreview(args)` |

Keep the table in one object literal so new MCP tools are one line each. While
the arguments are still streaming (`toolcall_start` → `toolcall_end`), show
`Preparing <tool words>…`.

**Tier 2 (optional, gated): model-written descriptions for `bash`.** This is
Claude Code's approach: bash takes an optional `description` ("what this
does, in 5–10 words") and the UI shows it. pi 0.87.1's bash schema
(`dist/core/tools/bash.js`) has only `command` and `timeout`. Options, in order:
1. A pi extension (`~/.pi/agent/extensions/tool-descriptions/`) that
   **re-registers `bash`** with the built-in implementation plus an optional
   `description` string, which the model fills and the tool ignores.
   **Verify first** that `pi.registerTool` may shadow a built-in name. The
   docs don't say, and the runner rejects conflicting *shortcuts*, so it may
   reject tools too.
2. If shadowing is not allowed: skip Tier 2. Don't prompt-engineer "narrate
   before each tool call": it costs tokens on every turn, and Siri answers
   would start narrating.
Tier 1 already reads `args.description`, so Tier 2 needs no UI change.

### 8.4 Tests
- node unit table for `describeTool` covering every row above, with missing or
  odd args (`null`, non-string query, an empty command).
- Fake-pi stream with **three parallel calls**, results arriving in reverse
  order: each row gets its own result and ends done, none keeps pulsing (L2).
- One error result → that row is red, the others green.
- Render the same turn live and from `/messages` → identical DOM row count and
  summaries (L3/L6). Same for `GET /session` on a past transcript.
- Visual: iPhone Safari screenshot shows coloured dots, not emoji squares (L4).
- Matrix/Siri unaffected (the change is UI-only, plus the L6 pass-through).

---

## Part C — Delete a session

### 9.1 Behaviour
- **Only non-live sessions** can be deleted (Previous or Archived). To delete
  the live one, switch away first. The daemon enforces this: 409
  `{"error":"that is the live session — switch to another one first"}`.
- **Soft delete:** move the file to `$AGENT_SESSION_DIR/trash/` (not listed
  anywhere). The janitor purges trash files older than 30 days
  (`AGENT_TRASH_DAYS`, default 30). There is no undelete UI in v1. Recovery is
  `mv` from `trash/`, or restic later: `~/.local/share` is inside the nightly
  `/home/nuc` backup, so a purged file stays in snapshots for the 14/8/12
  retention.
- Attachment files (`attachments/in|out/web-N…`) are keyed by request id, not
  by session, so they are **not** deleted. Say so in the README.

### 9.2 Endpoint: `POST /deletesession {file, dir}`
- Validation identical to `/opensession`: basename, `sessions|archive`
  allowlist, realpath containment → 400/404.
- Take the `switching` guard. Refuse with 409 while a switch is in progress,
  so a delete can't race an `/opensession` of the same file (and Part A's
  un-archive move).
- Inside the guard: `get_state` → if realpath equals the live `sessionFile`,
  return 409. Also refuse if it equals the `active-session` record, in case the
  record and pi disagree right after a restart.
- `os.replace` into `trash/`, adding a `-<unix-ts>` suffix before `.jsonl` to
  avoid collisions. Log `SESSION DELETED: <path> -> <trash path>`.
  Broadcast `{"type":"session_deleted","file":<basename>,"dir":<dir>}`.
- Response `{"ok":true,"trashed":<path>}`.

### 9.3 UI
- A **Delete** button in the "Viewing …" banner, next to Resume (Part A §4).
  It deletes the transcript you are looking at, so what gets deleted is never
  a guess. It is hidden for the live session, which can't be viewed in banner
  mode anyway.
- `confirm('Delete "<title>" (<n> msgs, <date>)? It moves to the trash and is
  purged after 30 days.')`
- On success: `returnToLive()`, `loadSessions()`, `sbMsg('Deleted')`.
- On the `session_deleted` event in any tab: `loadSessions()`. If that tab is
  viewing that file, `returnToLive()` + `sbMsg('that session was deleted')`.
- Old daemon (404) → `sbMsg('delete needs a daemon restart')`.

### 9.4 Tests
| # | Case | Expected |
|---|---|---|
| D1 | delete a Previous session | 200, file in `trash/`, gone from `/sessions`, SSE `session_deleted` |
| D2 | delete an Archived session | same |
| D3 | delete the live session | 409, file untouched |
| D4 | delete while `/opensession` is mid-switch | 409 |
| D5 | traversal / bad dir / missing | 400/404 |
| D6 | trash file 31 days old + janitor tick | purged; a 29-day-old one stays |
| D7 | tab A viewing X, tab B deletes X | A returns to live with the notice |
| D8 | restart after deleting the newest non-live file | restart still resumes the recorded active file (§17.7 unaffected) |

### 9.5 Out of scope
Bulk delete, an undelete UI, auto-cleanup of header-only empty sessions (e.g.
`sessions/2026-09-15T06-15-17-445Z…`, 661 bytes). The last one is a reasonable
follow-up.
