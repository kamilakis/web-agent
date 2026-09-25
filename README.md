# web-agent

A mobile-first web chat plus Siri and Matrix bridges for a persistent
[pi](https://github.com/earendil-works/pi-coding-agent) coding-agent session —
**one agent, three surfaces, one memory.**

Talk to the same always-on agent from your phone in three ways: dictate to Siri
and hear the answer spoken back, send a message in a Matrix room, or open a
chat-style web dashboard with live streaming, image attach/edit and tappable
choices. Everything lands in one long-lived session, so context follows you
across surfaces.

```
 Siri (Shortcuts/SSH) ─┐                      ┌─ spoken answer, or Matrix fallback
 Matrix room ──────────┼──▶ FIFO ──▶ daemon ──┼─▶ pi --mode rpc  (persistent session)
 web dashboard ────────┘         ▲   │        └─ Matrix post / SSE stream
                                 │   └─ HTTP + SSE control plane :8383
                          Matrix listener (long-poll sync, event-driven)
```

## Features

- **Persistent session** — one `pi --mode rpc` process with a fixed session id;
  full memory across restarts, shared by every surface. Restarts resume the
  **active** transcript (recorded in `$AGENT_SESSION_DIR/active-session`), not
  whichever namesake file pi's id lookup happens to pick first.
- **Siri** — dictate a command over SSH; short answers are spoken back, long
  ones fall back to Matrix.
- **Matrix** — an event-driven listener (server-held long-poll sync, not busy
  polling) forwards room messages to the agent; answers post back to the room.
- **Web chat** — mobile-first, light/dark:
  - live token streaming with tool-call rows (Claude Code style) and markdown —
    one row per call, described in plain language (`Running ls -la`) with the
    exact command and result behind a toggle, identical live and after a reload
  - **Stop** (`clear_queue` + `abort`) and **send-while-busy = steer**
  - model switcher, status dot, reconnect with snapshot re-render
  - **session history sidebar** — list, view, archive and create sessions;
    new sessions can be named at creation, and clicking the session name in
    the header renames the live one
  - **pictures**: attach from camera/roll (client-side downscale); the daemon
    auto-switches to a vision model when the session model is text-only
  - **image editing**: sent photos are saved to disk with their paths named in
    the prompt, so the agent edits them with ffmpeg; results render inline
  - **interactive choices**: the agent can end a reply with a `choose` block
    that renders as tappable buttons
  - **failures are loud**: a run that ends in a provider/runtime error
    (`stopReason: "error"`) renders as an error block in the transcript — live
    and after a reload — is logged as `status: error` in the task log, and is
    spoken/posted as an explicit failure instead of a blank answer
- **Session history sidebar** — every transcript pi writes stays on disk;
  the dashboard lists them (previous + archived), opens any of them
  read-only, and can **archive the running session** or **start a new one**
  without restarting the daemon:
  - `GET /sessions` — list `sessions/` and `archive/` with first-prompt
    title, message count and timestamps; the active file is flagged
  - `GET /session?file=&dir=` — one transcript as a messages snapshot
    (thinking stripped, tool results capped), rendered by the same snapshot
    renderer as the live view; basename + dir allowlist, `realpath`
    containment, image blobs dropped
  - `POST /opensession {file, dir}` — **resume an existing transcript** in
    place: switches pi onto that file and tells every tab to refresh. Same
    allowlist/containment as `/session`; the session keeps its own messages and
    name. A run in flight is stopped, and a Siri/Matrix caller waiting on it is
    told the run was interrupted instead of timing out. Resuming from
    `archive/` **moves the file back into `sessions/`** (so it is a normal live
    session again and re-archiving works) — 409 if that name is already taken
    there, and the file is moved back if the switch fails. An empty or
    non-JSON file is refused with 422. (Needed because a restart resumes the
    oldest file with the session id — docs/spec.md §17.5.)
  - `POST /newsession` / `POST /archive` — switch pi onto a fresh
    header-only session file (id preserved, so `--session-id` resume keeps
    working) and optionally move the old transcript to `archive/`. A run in
    flight is aborted first; a `session_switched` SSE event tells every open
    tab to refresh. RPC `new_session` was deliberately **not** used: it mints
    a random session id and would orphan the session on the next restart.

## Requirements

- [pi](https://github.com/earendil-works/pi-coding-agent) v0.85+ on the host
- Python 3.10+ (stdlib only — no pip dependencies)
- a Matrix account + room for the bridge (optional; skip it and use web + Siri)
- WireGuard or another private network for the dashboard (it speaks plain HTTP
  by design — no TLS inside the tunnel)

## Install

```bash
git clone https://github.com/kamilakis/web-agent.git
cd web-agent
./install.sh
```

`install.sh` copies `bin/*` to `~/.local/bin`, the chat to
`~/.local/share/agent-session/web/`, and the units to
`~/.config/systemd/user/`, then enables and starts both services.

### Post-install

1. **Matrix bridge** (optional): create a config dir with three plain-text
   files — `token`, `homeserver_url`, `room_id` — and point both services at it:

   ```bash
   mkdir -p ~/.config/web-agent/matrix
   printf '%s' 'https://matrix.example.org' > ~/.config/web-agent/matrix/homeserver_url
   printf '%s' '!roomid:example.org'         > ~/.config/web-agent/matrix/room_id
   printf '%s' 'syt_yourtoken'               > ~/.config/web-agent/matrix/token
   # in both unit files: Environment=AGENT_MATRIX_CONFIG=%h/.config/web-agent/matrix
   systemctl --user daemon-reload && systemctl --user restart agent-matrix-listener.service
   ```

2. **Siri** (optional): a Shortcuts automation — Dictate Text → *Run Script Over
   SSH* (`ssh <host> agent-task "Dictated Text"`, full path required) → Speak
   Text ← Shell Script Result.

   ⚠ **Put personal settings in a drop-in, not in the unit.** `install.sh`
   copies the generic `systemd/*.service` files over the installed units, so
   `Environment=` lines added to a unit by hand are lost the next time it runs
   (learned the hard way: a re-install dropped `AGENT_WEB_HOST` back to
   `127.0.0.1` and emptied `AGENT_MATRIX_SENDERS`, i.e. the dashboard went
   unreachable and the Matrix allowlist opened up). Use:

   ```bash
   mkdir -p ~/.config/systemd/user/agent-session.service.d
   cat > ~/.config/systemd/user/agent-session.service.d/local.conf <<'EOF'
   [Service]
   Environment=AGENT_WEB_HOST=192.0.2.10
   Environment=AGENT_MATRIX_CONFIG=%h/.config/web-agent/matrix
   EOF
   systemctl --user daemon-reload && systemctl --user restart agent-session
   ```

3. **chat**: open `http://<host>:8383` from a device on the private
   network. `AGENT_WEB_HOST` (default `127.0.0.1`) controls the bind address —
   set it to your VPN IP to reach the dashboard remotely.

## Tests

No dependencies, no network, and **nothing touches the live agent** — every
suite starts a throwaway daemon on its own port with a fake `pi` on `PATH`:

```sh
bash tests/run-all.sh          # everything
node tests/ui.test.js          # one suite
```

| Suite | Covers |
|---|---|
| `describeTool.test.js` | the plain-language tool descriptions (§8.3) |
| `toolRows.test.js` | tool rows: parallel calls, errors, live vs reloaded |
| `ui.test.js` | the page under a stub DOM: error surfacing, resume, two tabs |
| `opensession.test.sh` | resume against the daemon: T1–T8, T13 |
| `errors.test.sh` | a failed run is surfaced, never a silent empty answer |
| `resume.test.sh` | a restart resumes the recorded transcript, not the oldest namesake |

See `tests/README.md` for the fake pi's controls and the known gaps.

## Configuration

All knobs are env vars (set them in the unit files). Defaults are generic —
nothing personal is baked in.

| Var | Default | Meaning |
|---|---|---|
| `AGENT_PROVIDER` / `AGENT_MODEL` | `deepseek` / `deepseek-v4-pro` | pi provider and model |
| `AGENT_VISION_MODEL` | `deepseek/deepseek-v4-flash-vision-exp` | model auto-selected for image turns |
| `AGENT_SESSION_ID` | `siri-agent` | session id = memory key; change to wipe |
| `AGENT_SESSION_NAME` | `siri-agent` | display name for new sessions (the web UI can name them per-session) |
| `AGENT_TASK_WAIT` | `15` | seconds Siri holds the SSH call open |
| `AGENT_SETTLE_GRACE` | `30` | seconds before an unanswered answer falls back to Matrix |
| `AGENT_WEB_HOST` / `AGENT_WEB_PORT` | `127.0.0.1` / `8383` | dashboard bind address/port |
| `AGENT_WEB_TOKEN` | unset | optional bearer token (`Authorization: Bearer`, or `?token=` for `EventSource`) |
| `AGENT_WEB_ENABLED` | `1` | `0` disables the HTTP server |
| `AGENT_ATTACH_DIR` | `~/.local/share/agent-session/attachments` | image editing scratch space, served by `/media` |
| `AGENT_MATRIX_CONFIG` | `~/.config/web-agent/matrix` | dir with `token` / `homeserver_url` / `room_id` |
| `AGENT_MATRIX_SENDERS` | *(empty)* | allowlist of Matrix senders; empty = anyone except the bot |
| `AGENT_MATRIX_STATE_DIR` | `~/.local/state/agent-matrix-listener` | Matrix sync-token storage |

## Security notes

- The chat intentionally speaks plain HTTP — put it on a private network
  (WireGuard/Tailscale) and bind `AGENT_WEB_HOST` to that interface only.
- `AGENT_WEB_TOKEN` adds a bearer-token check on every route (including
  `?token=` for `EventSource`, which cannot send headers).
- `/media` serves only the attachments tree; `realpath` containment defeats
  path traversal and symlink escapes. Request bodies are size-capped (413).
  `/session` reads only `sessions/` and `archive/` by basename, with the same
  `realpath` containment.
- The Matrix listener only forwards text messages from `AGENT_MATRIX_SENDERS`
  (never the bot's own messages, never edits), and never replays history: the
  first sync advances until the stream token stops moving.
- The daemon holds no credentials; Matrix credentials live in a plain config
  dir you control.

## How it works

Three writers feed one FIFO that the daemon drains into a single pi session.
The daemon derives each run's *source* (siri / matrix / web) from pi's own
`agent_start` events — never from a guess — so answers always return to the
surface that asked: Siri gets a result file (spoken) with a Matrix grace
fallback, Matrix gets a room post, and the web dashboard streams everything
over SSE. See [`docs/spec.md`](docs/spec.md) for the full design, including the
run-state model, the vision-model auto-switch for image turns, and the
interactive-choice convention ([`docs/choose-convention.md`](docs/choose-convention.md)).

`docs/` also contains the design → external-LLM-review → build trail:
[`spec-review.md`](docs/spec-review.md) (12 findings, all resolved),
[`review-qwen72b.md`](docs/review-qwen72b.md) (an independent Qwen2.5-72B
review of the revised spec), and [`spec.md`](docs/spec.md) §17 (failed runs are
visible — the 2026-09-25 silent-failure incident and its fix).

## Acknowledgments

web-agent is a thin layer around [pi](https://github.com/earendil-works/pi) —
the agent, the tools, the session persistence and the whole interaction model
are pi's. Its `--mode rpc` JSONL protocol turned out to be a complete embedding
API: streaming deltas, per-tool progress, steering, abort, model switching and
even headless UI dialogs are first-class protocol events, and the docs match
the source line for line. This project is essentially a renderer and a few
buttons on top of it. Thank you.

## License

[MIT](LICENSE)
