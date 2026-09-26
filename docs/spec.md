# Web Dashboard — Blueprint (Option A) — rev 2

**Goal:** a mobile-first web UI on `http://<wg-ip>:8383` (WireGuard-only) that
drives the *same* persistent `siri-agent` session as Siri and Matrix, with live
streaming, a Stop button, steering, and model switching.

**Rev 6** (2026-09-12) adds interactive choices — tappable options when the
agent needs a decision. v1 (choice-block convention) built and verified live
(the model emitted the block unprompted from a CLAUDE.md instruction, and a tap
acted on the choice); v2 spec'd for later; see §16.

**Rev 5** (2026-09-11) adds deterministic image editing (ffmpeg / Pillow),
an incoming-image-to-file bridge, and a `/media` return path. Built and verified
end-to-end (agent resized a sent photo via ffmpeg; result rendered via
`web_attachments` + `/media`); see §15.

**Rev 4** (2026-09-11) adds image input — sending pictures from the phone.
Built and verified end-to-end (auto-switch to a vision model, image round-trip);
see §14.

**Rev 3** (2026-09-11) fixes five defects found in the built step-1..6 daemon;
see §13. The critical one: `agent_start` fires once per *low-level* run, not once
per prompt, so rev 2's attribution logic lost Siri and Matrix answers.

**Rev 2** incorporates the findings of `spec-review.md` (2026-09-11), verified
against pi v0.85.1 source: `_isAgentRunActive` flips false *before* the
`agent_settled` emit (line 348 vs 351 of `agent-session.js`), and `prompt` with
`streamingBehavior` is resolved atomically against `this.isStreaming` (line 843).
All 12 review issues are addressed inline; a mapping table is in §12.

---

## 1. Language decision: Python (not Go)

The HTTP layer must live in the process that owns pi's stdin/stdout. Writing it
in Go means rewriting the proven daemon (FIFO reader, Siri result-file + grace
fallback, Matrix posting, task logs — ~300 lines) to add ~250 lines. Not worth
it for one phone.

**Stdlib only:** `http.server.ThreadingHTTPServer` + SSE + `threading`. Python's
text-mode line iteration splits on LF/CR only (not U+2028), so the daemon's
reader is already JSONL-framing-compliant.

Go is worth it only if this becomes the general agent hub (attachments, session
switching, answering `extension_ui_request`, many clients). If that day comes,
rewrite the daemon in Go in one go — `bufio.Scanner` is LF-only compliant.

---

## 2. Architecture

```
iPhone (WireGuard <wg-ip>)
   │  GET  /                → static index.html (mobile-first)
   │  GET  /messages        → capped transcript snapshot (get_messages, last N)
   │  GET  /state           → isStreaming/model/msgCount (get_state)
   │  GET  /models          → available models (get_available_models)
   │  GET  /events          → Server-Sent Events (live pi events)  [token via ?token=]
   │  POST /prompt          → pi prompt (streamingBehavior:"steer")
   │  POST /abort           → pi clear_queue + abort
   │  POST /model           → pi set_model
   ▼
agent-session-daemon (Python, stdlib only)   ←── existing, extended
   ├─ owns: pi --mode rpc (session-id siri-agent)
   ├─ read_events(): routes agent_start/response/extension_ui_request,
   │                 broadcasts every event → SSE clients
   ├─ send_cmd_with_response(): state/models/messages (id-correlated)
   └─ web_prompt()/web_abort()/web_model(): immediate, bypass the FIFO queue
   ▼
pi --mode rpc  (unchanged)
   └─ same FIFO path serves Siri + Matrix (unchanged)
```

**Transport: SSE, not WebSocket.** One-way streaming; commands are POSTs. SSE is
stdlib-only. The frontend re-syncs by re-fetching `/messages` on reconnect.

**Security:** bind `<wg-ip>` only. Optional `AGENT_WEB_TOKEN`: fetch/other
requests carry `Authorization: Bearer`; `EventSource` **cannot send headers**, so
`/events` accepts the token as `?token=` (see §5.6, fix #3).

---

## 3. Run-state model (fixes #1 and #2 — the core change)

The daemon stops *guessing* run state. Two things are derived from pi's own
events, one thing is an optimistic dispatch guard:

| State | Set when | Cleared when |
|---|---|---|
| `busy` (a run is active) | `agent_start` read | `agent_settled` read, or `response success:false` |
| `current_source` (who owns the run) | the **first** `agent_start` of a run, from `last_dispatch_source` | `agent_settled` read |
| `pending` (optimistic, prevents double-dispatch) | any `prompt` sent while `not busy` | `agent_start` read, `response success:false`, or the watchdog after `DISPATCH_TIMEOUT` |

⚠ **`agent_start` is emitted once per low-level run, not once per prompt.**
`runAgentLoopContinue` re-emits it on every `agent.continue()`, and
`_runAgentPrompt` continues for each auto-retry, each auto-compaction and each
queued continuation (`pi-agent-core/dist/agent-loop.js:67`,
`agent-session.js:775-779`). Only the **first** `agent_start` of a run may set
`current_source`; a later one must not re-attribute the run, null `current_id`,
replace `current_prompt` or clear `last_text`. Attributing on every
`agent_start` sent any retried Siri or Matrix answer down the `"web"` branch of
`settle()`, where it was silently dropped.

`last_dispatch_source` is just the source (`"siri"` / `"matrix"` / `"web"`) of
the most recent `prompt` we wrote to pi — updated at every send.

**Why `current_source` is set on `agent_start`, not at dispatch:** pi flips its
internal idle flag *before* emitting `agent_settled`, so a prompt sent in that
gap may actually start a new run even though the daemon still thinks one is
active. `agent_start` tells us unambiguously that a run began, and
`last_dispatch_source` tells us which input began it. Delivery is therefore
never guessed.

**Dispatch rules:**

- **FIFO** (`maybe_dispatch`): only when `not busy and not pending`. Send
  `prompt` (plain, +`VOICE_HINT` for Siri), set `last_dispatch_source`,
  `pending=True`. On `response success:false`, **re-queue the prompt** into
  `self.q`, clear `pending`, and `maybe_dispatch()` again.
- **Web** (`web_prompt`): **always** send
  `{"type":"prompt","message":…,"streamingBehavior":"steer"}` and let pi decide
  atomically (idle → normal prompt; busy → steer). Set `last_dispatch_source="web"`.
  If `not busy`, also set `pending=True`. Never block on `self.lock` while
  calling `send_cmd` (fix #8).

**Settle:**

```python
def settle(self):
    with self.lock:
        source = self.current_source      # set by agent_start, authoritative
        prompt, pid, answer, asked = self.current_prompt, self.current_id, self.last_text, self.current_asked
        self.busy = False; self.pending = False; self.current_source = None
        self.current_prompt = self.current_id = self.current_asked = None
    # log + write_task_log(delivered=DELIVERY[source])
    if source == "siri":
        <result file + grace thread — unchanged>
    elif source == "matrix":
        threading.Thread(target=post_matrix, args=(msg,), daemon=True).start()   # fix #8: never block read_events
    elif source == "web":
        pass   # browser already streamed it
    self.maybe_dispatch()
```

`DELIVERY = {"siri": "spoken", "matrix": "matrix", "web": "web"}` (fix #9).

---

## 4. Daemon changes

### 4.1 Thread-safe command I/O

```python
def send_cmd(self, obj):
    with self.stdin_lock:                       # HTTP threads + event loop both write
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()
```

### 4.2 Request/response correlation (fix #4)

```python
def send_cmd_with_response(self, obj, timeout=15):
    with self.pending_lock:                     # cmd_seq bumped under the lock
        rid = f"cmd-{self.cmd_seq}"; self.cmd_seq += 1
        evt = threading.Event(); box = {}
        self.pending[rid] = (evt, box)
    self.send_cmd({**obj, "id": rid})
    if not evt.wait(timeout):
        with self.pending_lock: self.pending.pop(rid, None)
        raise TimeoutError(f"{obj['type']} timed out")
    return box["resp"]
```

### 4.3 `read_events()` additions

```python
elif t == "response":                       # fix #2 + #4
    rid = ev.get("id")
    with self.pending_lock: p = self.pending.pop(rid, None)
    if p: evt, box = p; box["resp"] = ev; evt.set()
    elif ev.get("command") == "prompt" and ev.get("success") is False:
        self.on_prompt_rejected(ev)          # re-queue FIFO prompt / clear pending

elif t == "agent_start":                    # fix #1 + #A (continuations)
    with self.lock:
        self.busy = True
        self.pending = False
        self.dispatch_deadline = None
        if self.pending_start_source:           # first agent_start of this run
            self.current_source = self.pending_start_source
            self.pending_start_source = None
            self.dispatch_map.clear()
        elif self.current_source is None:       # a run we never dispatched
            self.current_source = "web"         # web prompt in the settle gap
            ...
        # else: a continuation (retry / compaction / queued message) —
        # leave source, prompt, caller id and accumulated text alone

elif t == "extension_ui_request":           # fix #11: never let a dialog hang the run
    log("extension UI request:", ev.get("method"), ev.get("title"))
    if not ev.get("timeout"):
        self.send_cmd({"type": "extension_ui_response", "id": ev["id"], "cancelled": True})
```

`broadcast(ev)` is called for every event **except `cmd-*` responses**: a
`get_messages` reply is ~170 KB and its HTTP caller is already correlated to it
by id, so pushing it to every SSE client would mirror the whole transcript into
the live stream on each reconnect. `web-*` and `fifo-*` prompt responses stay
broadcast — they are small and let the page report a rejection.

```python
if not (t == "response" and str(ev.get("id") or "").startswith("cmd-")):
    self.broadcast(ev)
```

`on_prompt_rejected` runs its retry on a **worker thread** with 1 s / 3 s / 9 s
backoff and gives up after `MAX_PROMPT_ATTEMPTS`, writing the reason to the Siri
result file or posting it to Matrix. Sleeping on the event thread stalled SSE and
response routing, and an always-rejected prompt (a model switched to a provider
with no credentials) re-dispatched forever.

### 4.4 SSE server (fixes #3, #5, #9)

```python
class Handler(BaseHTTPRequestHandler):
    d = None                                   # fix #9: class attr, set before server start

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path      # fix #3: strip ?token=
        qs   = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if not self.authorized(qs): self.send_401(); return
        if   path == "/":          self.serve_index()
        elif path == "/events":    self.sse_stream()
        elif path == "/state":     self.json(Handler.d.send_cmd_with_response({"type":"get_state"}))
        elif path == "/messages":  self.json(self.capped_messages())
        elif path == "/models":    self.json(Handler.d.send_cmd_with_response({"type":"get_available_models"}))
        else: self.send_404()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path == "/prompt": self.json(Handler.d.web_prompt(body["message"]))
        elif self.path == "/abort":
            Handler.d.send_cmd({"type":"clear_queue"})
            Handler.d.send_cmd({"type":"abort"})
            self.json({"status":"aborting"})
        elif self.path == "/model":
            self.json(Handler.d.send_cmd_with_response(
                {"type":"set_model","provider":body["provider"],"modelId":body["modelId"]}))
        else: self.send_404()

    def sse_stream(self):
        q = queue.Queue(maxsize=200)
        with Handler.d.clients_lock: Handler.d.clients.append(q)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()
            self.wfile.write(b"retry: 3000\n\n"); self.wfile.flush()
            while True:
                try: line = q.get(timeout=15)          # fix #5: heartbeat
                except queue.Empty:
                    self.wfile.write(b": ping\n\n"); self.wfile.flush(); continue
                self.wfile.write(f"data: {line}\n\n".encode()); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with Handler.d.clients_lock:
                if q in Handler.d.clients: Handler.d.clients.remove(q)
```

### 4.5 Broadcast

```python
def broadcast(self, obj):
    line = json.dumps(obj)
    with self.clients_lock: clients = list(self.clients)
    for q in clients:
        try: q.put_nowait(line)                    # drop-slowest; never block the loop
        except queue.Full: pass
```

### 4.6 `/messages` cap (fix #12)

A tool result is a **top-level message with `role: "toolResult"`**, not a content
block of that type (`docs/rpc.md` → ToolResultMessage). Keying off the block type
caps nothing. Measured on the live 50-message snapshot (169 KB total):

| block | count | bytes |
|---|---|---|
| assistant `thinking` | 22 | 105,058 |
| `toolResult` text | 20 | 29,526 |
| assistant `toolCall` | 19 | 14,427 |
| assistant text | 7 | 3,213 |
| user text | 5 | 499 |

So capping tool results alone would save 3 %. Drop replayed `thinking` (the page
shows no old reasoning; live thinking still streams over SSE) and cap tool-result
text. Measured result: **169 KB → 50.7 KB**.

```python
msgs = (resp.get("data") or {}).get("messages", [])[-MSG_SNAPSHOT:]
out = []
for m in msgs:
    content = m.get("content")
    if not isinstance(content, list):
        out.append(m)            # a user message may carry a plain string
        continue
    blocks = []
    for x in content:
        if not isinstance(x, dict):
            blocks.append(x); continue
        if x.get("type") == "thinking":
            continue
        if m.get("role") == "toolResult" and x.get("type") == "text":
            t = x.get("text") or ""
            if len(t) > TOOL_RESULT_CAP:
                x = {**x, "text": t[:TOOL_RESULT_CAP] + "…"}
        blocks.append(x)
    out.append({**m, "content": blocks})
return {"messages": out}
```

### 4.7 Config (env vars, daemon defaults)

| Var | Default | Meaning |
|---|---|---|
| `AGENT_WEB_ENABLED` | `1` | `0` disables the HTTP server |
| `AGENT_WEB_HOST` | `<wg-ip>` | bind address (WG-only) |
| `AGENT_WEB_PORT` | `8383` | bind port |
| `AGENT_WEB_TOKEN` | unset | optional bearer token (defense in depth) |
| `AGENT_WEB_MSG_LIMIT` | `50` | messages in a `/messages` snapshot |
| `AGENT_WEB_TOOL_CAP` | `2048` | per-tool-result text cap in the snapshot |
| `AGENT_VISION_MODEL` | `deepseek/deepseek-v4-flash-vision-exp` | vision model auto-selected when a picture is attached, format `provider/modelId` (§14) |
| `AGENT_DISPATCH_TIMEOUT` | `30` | seconds to wait for `agent_start` before freeing the dispatch guard |
| `AGENT_JANITOR_INTERVAL` | `15` | seconds between janitor re-dispatch checks |
| `AGENT_MAX_PROMPT_ATTEMPTS` | `3` | rejections before a prompt is dropped and reported |

Server start (thread), wired correctly (fix #9):

```python
def start_web(self):
    if not WEB_ENABLED: return
    Handler.d = self                                    # class attribute, before server
    srv = ThreadingHTTPServer((WEB_HOST, WEB_PORT), Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log("web dashboard on http://%s:%d" % (WEB_HOST, WEB_PORT))
```

### 4.8 `run()`

```python
def run(self):
    self.start_pi()
    threading.Thread(target=self.read_fifo, daemon=True).start()
    self.start_web()
    self.read_events()                    # blocks; also broadcasts + routes responses
```

---

## 5. Frontend (`~/.local/share/agent-session/web/index.html`)

Single self-contained file, mobile-first: large touch targets, sticky bottom
input, `viewport` meta, dark theme.

### 5.1 Auth (fix #3)

```js
const TOKEN = location.search.match(/token=([^&]+)/)?.[1] || "";
const h = TOKEN ? { "Authorization": `Bearer ${TOKEN}` } : {};
const eventsUrl = "/events" + (TOKEN ? `?token=${encodeURIComponent(TOKEN)}` : "");
```

All `fetch` calls send `headers: h`; `EventSource(eventsUrl)` passes the token in
the query (it can't set headers).

### 5.2 Startup

```js
// The daemon already unwraps pi's `data`, so there is NO `.data` here.
// /state   -> the state object itself  ({isStreaming, model, messageCount, …})
// /models  -> {models: [...]}
// /messages-> {messages: [...]}
// A failed command comes back as HTTP 502 {error: "..."} instead.
const st = await (await fetch('/state', {headers:h})).json();
const models = (await (await fetch('/models', {headers:h})).json()).models;
const msgs = await (await fetch('/messages', {headers:h})).json();
renderTranscript(msgs.messages);
statusBar(st.isStreaming);
es = new EventSource(eventsUrl);
es.onmessage = onEvent;
```

### 5.3 Live events (fix #7: lazy bubble creation)

```js
let cur = null;                                  // current assistant bubble
function ensureCur() { if (!cur) cur = newAssistantBubble(); }

function onEvent(e) {
  const ev = JSON.parse(e.data);
  switch (ev.type) {
    case 'message_start':       cur = newAssistantBubble(); break;
    case 'message_update':
      const d = ev.assistantMessageEvent;
      if (d.type === 'text_delta')       { ensureCur(); appendText(d.delta); }
      else if (d.type === 'thinking_delta') { ensureCur(); appendThinking(d.delta); }
      else if (d.type === 'toolcall_start')  openToolRow(d.toolName);
      else if (d.type === 'toolcall_end')    closeToolRow();
      break;
    case 'tool_execution_update': updateToolRow(ev.partialResult); break;
    case 'tool_execution_end':     finishToolRow(ev.isError); break;
    case 'agent_start':            statusBar('working'); break;
    case 'agent_settled':          statusBar('idle'); finalizeCur(); cur = null; break;
    case 'queue_update':           renderQueue(ev); break;
  }
}
```

### 5.4 Controls (fix #6: provider/modelId in option value)

```js
// populate: option.value = `${model.provider}|${model.id}`
modelSel.onchange = () => {
  const [provider, modelId] = modelSel.value.split("|");
  fetch('/model', {method:'POST', headers:{...h,'Content-Type':'application/json'},
                   body: JSON.stringify({provider, modelId})});
};
send.onclick = () => fetch('/prompt', {method:'POST', headers:{...h,'Content-Type':'application/json'},
                                       body: JSON.stringify({message: input.value})});
stop.onclick = () => fetch('/abort', {method:'POST', headers:h});
```

Stop is shown while `state.isStreaming`; input stays enabled always (sending
while busy → `streamingBehavior:"steer"`, matching pi's "type while running").

### 5.6 Visual design (built 2026-09-11)

The page follows Claude's own look rather than a generic chat UI, so it reads as
the Claude Code app on a phone. **Do not regenerate `index.html` from the earlier
sections — they predate this and would drop the styling.**

- **Palette** as CSS custom properties, light and dark through
  `prefers-color-scheme`: cream `#faf9f5` / warm charcoal `#1f1e1d` grounds,
  terracotta `#c96442` (light) and `#d97757` (dark) as the only accent. Both
  `theme-color` metas are set, plus `apple-mobile-web-app-capable` so
  Add to Home Screen runs it chrome-free.
- **Turn treatment**: the person's turn is a rounded bubble on `--surface`; the
  agent's turn is plain prose on the page ground, as in the app. A terracotta
  block caret blinks at the end of the text while it streams.
- **Tool calls** keep the Claude Code idiom: a status dot (`⏺`, terracotta while
  running, green done, red error), the tool name in monospace, and a dimmed
  one-line argument preview, expanding to output behind a left rule.
- **Composer**: one rounded field; the circular terracotta send button becomes a
  stop button while a run is active. `[hidden] { display:none !important }` is
  required — `.iconBtn`'s `display:grid` otherwise beats the `hidden` attribute.
- **Markdown** is rendered by a ~15-line escaper-first pass (fences, inline code,
  bold, italic, headings, bullets, links). No CDN: the phone reaches this page
  over WireGuard and may have no route to the public internet.
- The daemon strips `VOICE_HINT` from user messages in `/messages`, so Siri's
  plumbing does not show up in the transcript.
- Prompts from Siri and Matrix are drawn from their `message_start` events, with
  a small `mine[]` list deduping the echo of what this page just sent.

### 5.5 Reconnect

On `EventSource` error: `close()`, re-fetch `/messages`, re-render, reopen.
**Note:** `/messages` omits the in-flight (mid-stream) message, so its partial
text is lost until `message_end` — accepted for v1 (fix #7).

---

## 6. systemd

No change to `agent-session.service` required. Optional pins:

```ini
[Service]
Environment=AGENT_WEB_ENABLED=1
Environment=AGENT_WEB_HOST=<wg-ip>
Environment=AGENT_WEB_PORT=8383
```

Verify: `ss -tlnp | grep 8383` shows `<wg-ip>:8383` (not `0.0.0.0`).

---

## 7. Build steps (ordered, each independently verifiable)

1. **Thread-safe `send_cmd` + `stdin_lock`** (mechanical). *Check:* Siri/Matrix still work.
2. **Run-state model** — `agent_start`/`agent_settled`/`response` routing,
   `last_dispatch_source`/`current_source`/`pending`, `on_prompt_rejected`.
   *Check:* Siri + Matrix prompt; task log `delivered` correct; force a rejection
   (prompt while busy) and confirm no wedge.
3. **`send_cmd_with_response`** (id under lock). *Check:* one-off `get_state`.
4. **`broadcast` + SSE server + routes** (no frontend). *Check:* `curl -N /events`
   streams while a prompt runs; `: ping` every 15 s.
5. **Frontend `index.html`** (transcript + input + stop + model + status + token).
6. **Web dispatch wiring** — `/prompt` (always `streamingBehavior:"steer"`),
   `/abort` (`clear_queue`+`abort`), `/model`, `/state`, `/messages` (capped),
   `/models`. *Check:* send from page, watch stream; Stop mid-run.
7. **Security** — bind `<wg-ip>`, `AGENT_WEB_TOKEN` enforcement (query for
   `/events`, header elsewhere).
8. **Polish** — `AGENT_WEB_ENABLED` kill-switch, auto-scroll, reconnect.
9. **Docs** — update README + memos note.

---

## 8. Test plan

```bash
# static + status (note: 401 if token set)
curl -s http://<wg-ip>:8383/ | head
curl -s http://<wg-ip>:8383/state
curl -s http://<wg-ip>:8383/models
curl -s http://<wg-ip>:8383/messages | python3 -m json.tool | head

# live stream (leave running, send a prompt from another shell)
curl -N "http://<wg-ip>:8383/events?token=$TOKEN"     # token if set

# prompt / steer / abort
curl -s -X POST -H 'Content-Type: application/json' -d '{"message":"say hi"}' http://<wg-ip>:8383/prompt
curl -s -X POST http://<wg-ip>:8383/abort
curl -s -X POST -H 'Content-Type: application/json' -d '{"provider":"deepseek","modelId":"deepseek-v4-pro"}' http://<wg-ip>:8383/model

# heartbeat: confirm ": ping" every ~15s when idle
# phone: open http://<wg-ip>:8383 in Safari over WireGuard
```

Acceptance checklist:
- [ ] Phone: transcript shows history; status shows model + idle/working.
- [ ] Send "what day is it" → answer streams live.
- [ ] Send a long task, then "actually stop and just say done" → steers mid-run.
- [ ] Stop during a long task → run halts, status → idle.
- [ ] Model dropdown switch → reflected in `/state`.
- [ ] Siri command works while the page is open (shared session).
- [ ] `ss -tlnp` shows `<wg-ip>:8383` only.
- [ ] Idle `curl -N /events` prints `: ping` (no silent death).

---

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| pi stdin from 2 threads | single `stdin_lock` |
| prompt-vs-steer race (pi idle, daemon thinks busy) | always `prompt`+`streamingBehavior:"steer"`; pi decides atomically (#1) |
| source guessed wrong at dispatch | `current_source` set on `agent_start` from `last_dispatch_source` (#1) |
| rejected prompt wedges daemon | `response success:false` → re-queue FIFO prompt, clear `pending`, `maybe_dispatch()` (#2) |
| `cmd_seq` collision across HTTP threads | bumped under `pending_lock` (#4) |
| slow/dead SSE client | bounded queue + `put_nowait` drop; `: ping` heartbeat + `retry:3000`; cleanup on write error (#5) |
| `read_events` blocked by Matrix post | Matrix delivery runs in a thread; `web_prompt` doesn't hold `self.lock` across `send_cmd` (#8) |
| extension dialog hangs a run | log + auto-`cancelled` when no `timeout` (#11) |
| transcript payload grows | `/messages` capped to last N + tool-result truncation (#12) |
| rare sub-ms race: FIFO prompt sent into a just-started web run | pi rejects it; rejection path re-queues it (at-least-once) (#2) |
| aborting a Siri/Matrix run | posts the truncated answer to Matrix (documented behaviour) |
| token leak via `/events` query | WG-only is the primary boundary; token is defense-in-depth (#3) |

---

## 10. Out of scope (future)

- Answering `extension_ui_request` dialogs in the web UI — now spec'd as §16.3
  (v1 logs + auto-cancels until then)
- Multi-user auth, non-image attachments/upload (images are §14), slash commands
  (`/commands`), session switching, compaction controls, HTML export — all exist
  in `RpcClient`, additive
- `Last-Event-ID` incremental replay (v1 re-renders from snapshot)
- TLS (unnecessary inside WireGuard)

---

## 11. Files touched

- `~/.local/bin/agent-session-daemon` — all §3/§4 changes
- `~/.local/share/agent-session/web/index.html` — new frontend
- `~/.config/systemd/user/agent-session.service` — optional env pins (no required change)

---

## 12. Review resolutions

| # | Review issue | Resolution |
|---|---|---|
| 1 | busy-flag race → steer swallowed by next Siri prompt | §3: always `prompt`+`streamingBehavior:"steer"`; derive run state from `agent_start`/`agent_settled`; `current_source` set on `agent_start` |
| 2 | rejected prompt wedges daemon | §3/§4.3: `on_prompt_rejected` re-queues FIFO prompt, clears `pending`, re-dispatches |
| 3 | token scheme contradiction (EventSource can't send headers) | §4.4/§5.1: `urlsplit` path; `/events` takes `?token=`; fetch uses `Authorization` header |
| 4 | `cmd_seq` race | §4.2: bumped under `pending_lock` |
| 5 | no SSE heartbeat / dead clients | §4.4: `q.get(timeout=15)` + `: ping`; claim corrected |
| 6 | frontend `provider` undefined | §5.4: `provider|modelId` in option value, split on change |
| 7 | joining mid-stream crashes renderer | §5.3: lazy `ensureCur()`; §5.5 notes `/messages` omits in-flight message |
| 8 | responses routed by event thread that `settle()` blocks | §3: Matrix post in thread; `web_prompt` releases lock before `send_cmd` |
| 9 | task log says `matrix` for web; `Handler.d` never wired | §3 `DELIVERY` map adds `"web"`; §4.7 `Handler.d = self` before server |
| 10 | Stop doesn't clear FIFO backlog | §8/§9: documented as intended; abort of Siri/Matrix run posts truncated answer |
| 11 | `extension_ui_request` dialogs hang | §4.3: log + auto-`cancelled` when no `timeout`; web UI answers in v2 |
| 12 | `get_messages` unbounded | §4.6: cap last N, drop replayed thinking, truncate tool results |

---

## 13. Rev 3 resolutions (defects found in the built daemon)

| # | Defect | Resolution | Verified by |
|---|---|---|---|
| A | every retry/compaction `agent_start` re-attributed the run to `"web"`, losing Siri and Matrix answers | §3/§4.3: only the first `agent_start` attributes; continuations leave state alone | offline event-stream test: before = `settled as ['web']` + no result file, after = `['siri']` + result file; live `delivered: spoken` |
| B | a prompt accepted but never started (extension command, post-preflight failure) left `pending` set forever, stalling the FIFO | `DISPATCH_TIMEOUT` watchdog in `maybe_dispatch`, a `JANITOR_INTERVAL` thread, and `agent_settled` clearing the guard even when not `busy` | offline: watchdog dispatches after a wedge; a fresh pending is still respected |
| C | `on_prompt_rejected` slept 1 s **on the event thread** and retried forever | worker thread, 1/3/9 s backoff, `MAX_PROMPT_ATTEMPTS`, reason reported to the caller | offline: retried twice, gave up on the third, caller got the reason |
| D | `cmd-*` responses were broadcast, mirroring the 170 KB transcript to every SSE client | broadcast filter in §4.3 | live: 34 s of SSE during a `/messages` fetch carried 29 bytes, only pings |
| E | the tool-result cap targeted a block type that does not exist, so nothing was capped | §4.6 keyed on `role`, plus dropping replayed thinking | live: `/messages` 169 KB → 50.7 KB, 0 thinking blocks, 0 over-cap results |
| F | §5.2 read `st.data.isStreaming` / `models.data.models`, both `undefined` | §5.2 corrected; `_command` now returns `data` or HTTP 502 `{error}` | live: `/state` → `{"model": …}`, `/models` → `{"models": […]}` |

---

## 14. Image input (pictures)

### 14.1 Model constraint

The default model `deepseek-v4-pro` is **text-only** (`input:["text"]`); pi will
not accept an image for it. Vision-capable models currently configured:

| provider | model | input |
|---|---|---|
| deepseek | `deepseek-v4-flash-vision-exp` | text, image |
| deepseek | `deepseek-flash` | text, image |
| anthropic | any `claude-*` | text, image |

So sending a picture requires the run to be on a vision model. pi's wire format
already supports it (`docs/rpc.md`, `prompt`/`steer` commands):

```json
{"type":"prompt","message":"what's this?",
 "images":[{"type":"image","data":"<base64>","mimeType":"image/jpeg"}]}
```

### 14.2 Flow

```
phone camera/roll
  → <input type="file" accept="image/*" hidden>       (a .iconBtn in #compose triggers it)
  → JS: FileReader → <img> → offscreen canvas downscale (long edge ≤1568px)
        → toDataURL('image/jpeg', 0.8)  → strip the data: prefix
  → POST /prompt { message, images:[{type:"image", data:<b64>, mimeType:"image/jpeg"}] }
  → Handler.do_POST reads body.images → Daemon.web_prompt(message, images)
  → (idle + text-only model) set_model AGENT_VISION_MODEL, then prompt+images (+streamingBehavior steer)
  → vision model answers → SSE streams back as usual
```

### 14.3 Frontend changes (respect §5.6 styling — do not restyle)

- A camera icon button (`#attachBtn`, an `.iconBtn` like send/stop) inside
  `#compose`, left of the send button, toggling a hidden
  `<input type="file" accept="image/*">`. iOS offers Camera / Photo Library.
- On selection: downscale on an offscreen `<canvas>` (long edge ≤1568px),
  re-encode `image/jpeg` q0.8, keep the base64 **without** the `data:` prefix.
  A raw phone photo is 3–8 MB; this brings it to ~200–500 KB so the single JSON
  line over pi's stdin stays sane.
- A preview pill above the composer (a `--surface` chip with a thumbnail and a
  remove ✕). `send()` includes it: `body: JSON.stringify({message, images})`,
  and clears the preview after send.
- `renderSnapshot` and the live `message_start` user branch must render `image`
  content blocks as `<img>` inside the user bubble (`.msg.user .bubble img`,
  rounded, max-width ~70%). The same `mine[]` dedup applies.
- Since `/models` already returns each model's `input`, the page may grey the
  send button when a picture is attached to a text-only model — mostly moot once
  the daemon auto-switches.

### 14.4 Backend changes

- `web_prompt(self, message, images=None)`; `do_POST /prompt` reads
  `body.get("images")` and defaults the message to `"What's in this image?"`
  when only a picture is attached.
- Config: `AGENT_VISION_MODEL` (default
  `deepseek/deepseek-v4-flash-vision-exp`, format `provider/modelId`).
- Model-capability cache: `self.model_input` (list), fetched lazily by
  `_model_accepts_images()` from `get_state` and refreshed by `model_set()` after
  every `set_model` (both the `/model` route and the auto-switch call it).
- Auto-switch rule in `web_prompt`:
  - `images` + current model text-only + **starting** → `model_set`
    `AGENT_VISION_MODEL` first, then `prompt`+`images`.
  - `images` + current model text-only + **steering** → return an error to the
    page (`{"error": "the current model can't see pictures and a run is in
    progress — stop it first…"}`); a steer cannot change the model of a run
    already in flight.
- Auto-return to the prior model after the image turn settles is a v2 nicety; v1
  stays on the vision model and the user switches back in the dropdown.

### 14.5 Snapshot / reconnect

`/messages` user messages carry `image` content blocks with base64; on reconnect
the page re-renders them from the snapshot. Bounded by the client-side downscale
(§14.3), so no server-side stripping is needed for v1. If snapshots ever grow,
strip image `data` and substitute a placeholder — the page knows what it sent.

### 14.6 Other surfaces

- **Matrix** (future): Element sends `m.image` (mxc:// URL + `info`); the
  listener downloads it via `/media/v3/download/{server}/{mediaId}`, base64s it,
  and POSTs to `/prompt` with `images` — the daemon's HTTP API makes this
  near-free.
- **Siri**: out of scope (SSH/Shortcut is text-only; a photo through a Shortcut
  is not worth the plumbing).

### 14.7 Risks

| Risk | Mitigation |
|---|---|
| image on a text-only model silently dropped | auto-switch on idle; explicit error on steer (§14.4) |
| 8 MB photo → giant JSON line over stdin | client canvas downscale (§14.3) |
| `/messages` bloat from base64 | bounded by downscale; strip-to-placeholder if needed (§14.5) |
| steering an image mid-run | rejected with a clear message; Stop first |
| experimental vision model (`-exp`) | `AGENT_VISION_MODEL` configurable; claude-* as the quality option |

---

## 15. Image editing (deterministic)

### 15.1 Scope and honest boundaries

The agent can **deterministically** edit images — it runs real tools (`bash`) on
files, not pixels in the model. `ffmpeg` 7.1.5 is already installed; Pillow and
ImageMagick are not (optional `pip install pillow` / `apt install imagemagick`).

| Edit | Tool |
|---|---|
| resize, crop, rotate, flip, format convert | ffmpeg |
| brightness/contrast/saturation, curves, palette | ffmpeg |
| text/watermark overlay, compositing, montage | ffmpeg (drawtext/overlay) |
| Pythonic per-pixel work | Pillow (to install) |

**Not generative.** No configured model outputs pixels — the vision model only
*reads* images. "Remove the person", "repaint as watercolor", "extend the
frame" are impossible without an image-generation model/API; see §15.8.

### 15.2 The two gaps to close

1. **Incoming photo isn't a file.** A sent picture lives as base64 inside the
   conversation; the vision model sees it, but `bash`/`ffmpeg` cannot. Fix: the
   daemon saves each incoming image to disk and tells the agent the path.
2. **No return path.** The answer streams back as text only. Fix: a sandboxed
   `/media` endpoint + a `web_attachments` SSE event so produced images render
   in the transcript.

(Images already on the host's disk can be edited *today* with ffmpeg — the user
just can't see the result in the chat. The two gaps are only about the chat loop.)

### 15.3 Flow

```
user attaches photo → §14 downscale → POST /prompt {message, images}
  → web_prompt: assign turn id N
     save each image → ATTACH_DIR/in/web-N-<i>.<ext>
     append hint: "images at <in paths>; save outputs to ATTACH_DIR/out/web-N/"
  → pi prompt (message + hint + images) → vision model sees it, bash edits it
  → settle(source=web): scan ATTACH_DIR/out/web-N/ for new files
     broadcast SSE {"type":"web_attachments","files":[{name,url}]}
  → frontend renders each file as <img src="/media/...?token=…">
```

### 15.4 Daemon changes

- **Config**: `AGENT_ATTACH_DIR` (default
  `~/.local/share/agent-session/attachments`), with `in/` and `out/` subdirs.
- **Save incoming** (in `web_prompt`, before dispatch, outside the lock): decode
  base64, write `in/web-<seq>-<i>.<ext>` (`.jpg`/`.png`/`.webp`/`.gif` from
  `mimeType`). Store the per-turn out dir `out/web-<seq>/` in dispatch state
  (e.g. `self.current_out_dir`) so `settle()` can find it.
- **Prompt hint** (only when images present), stripped from `/messages` like
  `VOICE_HINT`:

  ```
  [Attached image(s), saved to disk for editing:
   <in paths>. Edit with ffmpeg as requested. Save any output image to
   <out dir> with a descriptive filename; it will be shown to the user.]
  ```

- **Return path** in `settle()` for `source == "web"`: list `self.current_out_dir`
  and broadcast one `web_attachments` event with
  `files=[{name, url: "/media/out/web-N/<name>"}]` for each file (images only for
  v1; other file types are skipped).
- **`/media/<subpath>`** (GET): serve files under `ATTACH_DIR` only.

  ```python
  def _media(self, subpath):
      root = os.path.realpath(ATTACH_DIR)
      p = os.path.realpath(os.path.join(root, subpath))
      if not (p == root or p.startswith(root + os.sep)):
          return self._json({"error": "not found"}, 404)   # no traversal
      if not os.path.isfile(p):
          return self._json({"error": "not found"}, 404)
      ctype = mimetypes.guess_type(p)[0] or "application/octet-stream"
      # send_response + Content-Type + Content-Length, then wfile.write(bytes)
  ```

  Auth: same as every route (`?token=` for `<img src>` — image tags can't send
  headers).

### 15.5 Frontend changes (respect §5.6 styling)

- Handle the `web_attachments` SSE event: render a new assistant row of produced
  images — small rounded `<img>` tiles (reuse the `.msg.user .bubble img.attach`
  visual, but in an assistant context), each opening the full image on tap
  (or `target="_blank"`). Append `?token=` to the `/media/...` URL.
- No change to the composer — attach/send is already §14.

### 15.6 Security

| Concern | Mitigation |
|---|---|
| path traversal via `/media/../../etc/passwd` | `realpath` containment check (§15.4) |
| serving arbitrary files | sandboxed to `ATTACH_DIR`; GET only |
| oversized output image | note a soft cap (e.g. refuse > 20 MB) or rely on WG-only |
| unauthenticated media | `?token=` like `/events` |

### 15.7 Config

| Var | Default | Meaning |
|---|---|---|
| `AGENT_ATTACH_DIR` | `~/.local/share/agent-session/attachments` | where incoming images are saved and `/media` serves from |
### 15.8 Out of scope / future

- **Generative editing** — requires an image-gen model/API (none configured);
  would be a separate integration, not a spec tweak.
- **Matrix return path** — the bot would `m.upload` the file and post an
  `m.image` to the room; additive later, and only relevant for Matrix-originated
  requests.
- **Toolbox** — installing Pillow / ImageMagick to broaden ffmpeg's coverage.

### 15.9 Build steps

1. `AGENT_ATTACH_DIR` + `in/`/`out/` scaffolding.
2. Save incoming images + append the path hint (strip hint in `/messages`).
   *Check:* send a photo, confirm `in/web-N-*.png` exists and the transcript
   shows no hint text.
3. `/media` endpoint with `realpath` containment. *Check:*
   `curl -I http://<wg-ip>:8383/media/in/web-N-1.png` → 200; `/media/../daemon.log` → 404.
4. `settle()` scan of `current_out_dir` + `web_attachments` broadcast.
5. Frontend `web_attachments` rendering.
   *Check:* attach a photo, ask "crop to square and send it back" → the edited
   image appears in the transcript.
6. Docs (README + memo).

### 15.10 Test plan

```bash
# /media sandbox
curl -s -o /dev/null -w '%{http_code}' http://<wg-ip>:8383/media/in/web-1-1.png   # 200
curl -s -o /dev/null -w '%{http_code}' --path-as-is 'http://<wg-ip>:8383/media/../daemon.log'  # 404

# end-to-end: attach a photo, prompt "resize to 400px wide and save as resized.png"
# → web_attachments event on /events, then <img> in the transcript
```

### 15.11 Risks

| Risk | Mitigation |
|---|---|
| agent doesn't follow the "save to out/" instruction | clear hint; the out-dir is fixed and named; user can retry |
| turn id / out-dir mismatch on steer | store `current_out_dir` only when starting a new run; ignore for steers |
| stale files in `out/web-N/` across runs | per-turn dirs are unique (`web-<seq>`); never re-scanned |
| ffmpeg output huge | client-side downscale in (§14.3) bounds inputs; optional output cap |
| vision model lacks tool-use | deepseek vision is OpenAI-compat with tools; verify in step 2 |

---

## 16. Interactive choices (clickable options)

**v1 built and verified** (§16.2); v2 (pi-native dialogs) spec'd for later (§16.3).

### 16.1 The problem (observed live)

Asked for favicon options, the agent listed them in prose and asked which one to
use. On the phone there was nothing to tap — the choice had to be copy-pasted
back as a message. Two mechanisms can make options clickable, and they cover
different cases:

| | A. choice-block convention | B. pi-native dialogs |
|---|---|---|
| what triggers it | the model emits a fenced `choose` block in its reply | an extension calls `ctx.ui.select()` etc. |
| covers the favicon case | ✅ (model-driven list) | only via a `choose` **tool** extension |
| pi internals touched | none | dialog routing + a tool extension |
| run blocks awaiting the answer | no (choice arrives as the next message) | **yes** — a timeout is mandatory |
| works on any model | yes | yes (tool-use required) |
| effort | small: frontend + one instruction | medium: extension + routing + policy |

### 16.2 v1 — choice-block convention (recommended first)

**Convention.** When the agent needs a decision it ends its reply with:

    ```choose
    Which favicon?
    - favicon-a.png
    - favicon-b.png
    ```

First non-empty line = the question; `- ` lines = options (2–6). The block is
the last thing in the reply.

**Where the instruction lives.** The project context file pi already loads for
this session — `CLAUDE.md` (or `AGENTS.md`) in the daemon's workdir
(`~/assistant`). Zero per-prompt cost, in context for every turn, nothing to
strip. The instruction must say: options one per line prefixed `- `, 2–6
options, block last, and **skip the block on voice (Siri) turns unless the
choice is essential** (a spoken list of buttons is noise). A daemon-appended
hint (strippable like `HINT_MARK`) is the fallback if context-file loading
proves unreliable.

**Frontend parsing & rendering.**
- Parse an assistant message's raw text for the LAST closed ` ```choose ` fence:
  first non-empty line = question, `- ` lines = options.
- Replace that rendered code block with a button group — question as a small
  label, one pill per option (§5.6 styling: `--surface` pills, accent on press).
- **Staleness rule**: buttons render only if this is the last assistant message
  AND no user message follows it; otherwise render the block as plain text.
  This keeps reconnect/snapshot re-renders consistent after a choice was made.
- **Tap** = send the option text verbatim as the next user message — push to
  `mine[]`, `appendUser(option)`, `POST /prompt {message: option}` (all existing
  machinery) — then collapse the buttons to a `→ <option>` chip.
- **Ordering**: parse at `agent_settled` BEFORE `resetStream()` (the raw text
  lives on the streaming bubble, which resetStream clears), and in
  `renderSnapshot` under the staleness rule. While streaming, an open fence just
  renders as a code block.

**Other surfaces.** Matrix shows the block as plain text (fine); Siri speaks a
short answer (the instruction discourages blocks on voice turns). No changes
needed there.

### 16.3 v2 — pi-native dialogs (follow-up)

The fuller Claude-app experience: the *model* triggers a real dialog by calling
a tool (verified: custom tools get `ctx` and may await `ctx.ui.*`, which in RPC
mode surfaces as `extension_ui_request`).

- **Extension**: a small pi extension registers a `choose` tool
  (`{question, options[]}`) whose `execute` awaits `ctx.ui.select(...)` and
  returns the picked option as the tool result — the model continues with the
  answer in hand, no second user message needed.
- **Daemon**: stop auto-cancelling dialogs (§4.3); forward them to SSE as
  `{"type":"ui_dialog","id":…,"method":"select","title":…,"options":[…]}` and
  add `POST /ui-response {id, value|confirmed|cancelled}` that writes the
  matching `extension_ui_response` to pi.
- **Mandatory timeout**: a dialog blocks the run; if no page answers within
  ~120 s the daemon sends `cancelled` so the run can settle. This replaces
  today's instant auto-cancel.
- **Multi-surface policy**: any open page can answer — including dialogs raised
  during Siri/Matrix runs. A Siri caller's 15 s window elapses while the dialog
  is open, and the Matrix fallback only lands after the dialog resolves (the run
cannot settle before then) — document this.
- **Frontend**: `select` → buttons, `confirm` → ✓/✗, `input` → text field with
  send.

### 16.4 Enhancement (optional)

If an option references a produced attachment (§15), render its thumbnail AS the
button — for "which favicon?" the tiles themselves become the choices.

### 16.5 Risks

| Risk | Mitigation |
|---|---|
| model forgets the block (convention drift) | benign — copy/paste still works; instruction lives in the context file so it is always in context |
| buttons re-render after the choice was made | staleness rule (last assistant message + no following user message) |
| streaming renders a half-open fence | parse only at `agent_settled` / snapshot |
| tap produces a duplicate user bubble | reuse the existing `mine[]` dedup |
| v2 dialog deadlocks the run with no page open | mandatory daemon-side timeout → `cancelled` |
| v2 dialog during a Siri run | 15 s waiter falls back to Matrix after resolution; documented |

### 16.6 Build order

**v1**: 1) add the convention section to `~/assistant/CLAUDE.md`, 2) frontend
parser + renderer + staleness rule, 3) test: "propose 3 favicons, save them, and
ask me to choose" → tap one → the agent acts on the choice.

**v2**: 4) `choose`-tool extension, 5) daemon dialog routing + timeout,
6) frontend dialog rendering, 7) multi-surface test (raise a dialog during a
Siri run, answer it from the web page).

---

## 17. Failed runs are visible (built 2026-09-25)

### 17.1 The bug (observed live)

On 2026-09-25 every web prompt settled instantly with `dur_s= 0.1
answer_len= 0` and no error anywhere:

```
[07:45:00] WEB PROMPT -> Hello new
[07:45:00] SETTLED. prompt= Hello source= web dur_s= 0.0 answer_len= 0 answer=
```

The answer was not empty — it had **failed**. The transcript held the reason:

```
{"role":"assistant","content":[],"stopReason":"error","usage":{"input":0,...},
 "errorMessage":"Cannot find module
  '.../dist/bundle/chunks/openai-completions-EKZT2IH2.js'"}
```

pi had been upgraded in place to 0.87.1 four days earlier; the long-running
`pi --mode rpc` process (started Sep 21) still held the previous bundle's chunk
paths, so every prompt died before the first token. Cause was environmental, but
the *silent* part was ours: `settle()` delivered `last_text` — empty — and
reported success:

- the dashboard drew a user bubble and nothing else,
- Siri's result file got an empty string, so Siri spoke nothing,
- Matrix posted `🤖 <prompt>` with a blank body,
- `tasks/*.log` said `delivered: web` with `answer: (no text)`.

An aborted run and a *failed* run were indistinguishable from a run that
returned nothing, which is the one outcome a chat UI must never fake.

### 17.2 Fix — `stopReason: "error"` is a run outcome

A terminal errored assistant message (`message_end`, `role: "assistant"`,
`stopReason: "error"`, `errorMessage`) is captured in `read_events()` into
`self.last_error`, cleared on dispatch, on the first `agent_start` of a run, and
by any later successful assistant message:

```python
if m.get("role") == "assistant":
    if m.get("stopReason") == "error":
        self.last_error = (m.get("errorMessage") or "").strip() or \
                          "the model returned an error"
        log("RUN ERROR:", err)
    elif m.get("stopReason") in ("stop", "toolUse", "length"):
        self.last_error = None      # pi auto-retried and recovered
```

The clear-on-success branch matters: pi retries provider errors by itself
(`auto_retry_start`), so a failure followed by a good answer is a *recovered*
run, not a failed one. `auto_retry_start` is now logged too, so the journal
shows the retry even when it works.

`settle()` then treats `error` as part of the outcome:

| Surface | On failure |
|---|---|
| daemon log | `SETTLED. … error=<message>`, plus the `RUN ERROR:` line |
| `tasks/*.log` | `status: error` and `error: <one-line message>` |
| Siri | result file gets `⚠ The agent failed: <message>` (spoken, then the usual Matrix grace) |
| Matrix | `🤖 <prompt>` + `⚠ The agent failed: <message>` |
| web | the error bubble, rendered from `message_end` (live) and from the snapshot |

A partial answer is preserved: if text streamed before the failure, that text is
still what Siri/Matrix receive (`spoken = answer or failure line`) and the
dashboard shows the partial text with the error bubble beneath it.

### 17.3 Frontend

`errorBubble(text)` renders `.bubble.err` — a danger-bordered block with a
`⚠ agent error` heading and the message in monospace. It is used in two places,
so a failure looks the same live and after a reload:

- `message_end` with `stopReason === 'error'` → appended to the running
  assistant message (after whatever streamed),
- `renderSnapshot` → appended to that message's row, which previously rendered
  *nothing* for an empty-content assistant message (the `if (msg.children.length)`
  guard swallowed it).

`docs/spec.md` §5.6 styling is respected: `--danger`/`--surface` tokens, no new
palette.

### 17.4 Test plan (executed 2026-09-25)

Hermetic harness in `/tmp/errtest`: a fake `pi` on `PATH` replays a scripted RPC
sequence (`agent_start`, `message_start`, `message_end{stopReason:error}`,
`agent_settled`), and the daemon runs against a throwaway state dir, port and
FIFO (`AGENT_SESSION_DIR=/tmp/…`, `AGENT_WEB_PORT=8399`, `AGENT_QUIET_MATRIX=1`).
Nothing touches the live agent.

| Scenario | Expected | Result |
|---|---|---|
| `error` + web | SSE carries the errored `message_end`; `status: error`; `RUN ERROR:` logged | ✅ |
| `errorbare` + Siri | result file = `⚠ The agent failed: …` | ✅ |
| `retry` (error → success) | `status: ok`, answer delivered, retry logged | ✅ |
| `ok` + Siri | unchanged | ✅ |
| UI: snapshot with an errored assistant message | one `.bubble.err`, heading + `errorMessage` | ✅ |
| UI: live `message_end` error | error bubble after the partial text | ✅ |
| UI: healthy turn | no error bubble | ✅ |

The UI checks ran the real `web/index.html` script under a stub DOM
(`node ui.test.js`), since no headless browser is installed.

### 17.5 Follow-ups found while diagnosing (NOT fixed here)

1. **Restart resumed the OLDEST session file, not the active one.**
   `--session-id` resolves to *a* project session with that id when several
   exist, and pi takes the **first match by filename (oldest)**, not the newest:
   reproduced with two files (`2026-01-01…_testid.jsonl`,
   `2026-06-01…_testid.jsonl`, created in both mtime orders) → pi opened the
   January one. Live consequence: the daemon was on `/sessions/2026-09-14…`
   (245 messages) after a restart, while the session the user had just created
   ("Email quote", `2026-09-25T04-44-27-413Z_siri-agent.jsonl`) sat orphaned.
   Every restart silently rewound to the first transcript of that id.
   **Fixed in §17.7** the same day.
2. **A stale pi bundle is invisible until a prompt runs.** An in-place `npm`
   upgrade under a running daemon breaks the next prompt only. Recording
   `pi --version` (or the bundle mtime) at `start_pi()` and comparing on each
   run — restarting if it moved — would catch it before the user does.

### 17.6 Resuming an existing session (built 2026-09-25)

Diagnosing §17.5 exposed a gap: `switch_to_new` can only start a **fresh**
session (a crafted header-only file), and a restart resumes the oldest file
with the session id. So there was no way back to a specific transcript — the
one that was live before a restart, or any past session the sidebar shows.

`POST /opensession {file, dir}` closes that. Validation is identical to `GET
/session` (basename + `sessions`/`archive` allowlist, `realpath` containment),
then the daemon aborts any in-flight run, sends
`{"type":"switch_session","sessionPath":<path>}` and broadcasts
`session_switched`, so every open tab re-reads and re-renders — the same event
`/newsession` and `/archive` already use. The opened file keeps its own
messages and its own name (`sessionName` comes back in the response).

| case | response |
|---|---|
| switched | `{"ok":true,"oldFile":…,"newFile":…,"name":…}` |
| already open | `{"error":"that session is already open"}` |
| `../` in `file`, `dir` outside the two roots, non-`.jsonl` | HTTP 400 |
| missing file | HTTP 404 |

Tested against a scripted fake pi (`switch_session` moves its reported
`sessionFile`) — `/state` confirms the move, the journal logs `SESSION
OPENED: old=… new=… name=…`, and all four rejection cases return 400/404.

**Still open:** this switches *now* but does not survive a daemon restart —
see §17.5 #1. The endpoint is the mechanism a fix would use at startup
("resume the recorded active file"), which is why it exists before the rest of
that fix landed.

### 17.7 Restart resumes the active session (built 2026-09-25)

The §17.5 #1 fix. `start_pi()` now resumes a *file*, not an id:

```python
resume = self.resume_target()          # the recorded active transcript
if resume:  cmd += ["--session", resume]
else:       cmd += ["--session-id", SESSION_ID, "-n", SESSION_NAME]
```

**The record.** `$AGENT_SESSION_DIR/active-session` holds the absolute path of
the live transcript, written atomically (`.tmp` + `os.replace`) at startup by a
tracker thread that asks pi for its `sessionFile`, and on every switch
(`/newsession`, `/archive`, `/opensession`). `resume_target()` prefers it, falls
back to the newest valid `*_<SESSION_ID>.jsonl` when it is missing or stale, and
returns `None` (→ brand-new session) only when there is nothing to resume.

**Three details that are not obvious:**

- **`-n` is omitted when resuming.** A name flag is written into the transcript
  as a `session_info` and *renames* the resumed session — verified: resuming a
  file whose last `session_info` said "Email quote" with `-n siri-agent` appended
  `{"name":"siri-agent"}` and the header showed that instead. Without `-n`, the
  transcript's own name survives (and one is only needed for a new session).
- **Resume targets are validated** (`_valid_session_file`: non-empty, first line
  a `{"type":"session"}` header). A resume target pi cannot parse would make it
  exit on startup and systemd would restart into the same file — a crash loop.
  Invalid candidates are skipped, including in the newest-file fallback.
- **The record is confined** to `sessions/` and `archive/` by `realpath`;
  anything else is ignored. Archived transcripts stay resumable, since
  `/opensession` can open them.

Not used: `-c/--continue` ("most recent session for the project") — it picks by
its own idea of recency, which is the bug being fixed, and cannot express "the
one the user last switched to".

### 17.8 Test plan for §17.7 (executed 2026-09-25)

Same hermetic harness; the fake pi records the argv it was started with, so the
daemon's resume decision is asserted directly. 17/17 pass.

| Case | Expected | Result |
|---|---|---|
| fresh start, no files, no record | `--session-id … -n …`, no `--session` | ✅ |
| restart with a record, older namesake present | opens the **recorded** file, not the oldest | ✅ |
| record points at a deleted file | falls back to the newest *valid* transcript | ✅ |
| newest files empty / unparseable | skipped; the previous good one is used | ✅ |
| record points outside `sessions`+`archive` (`/etc/passwd`) | refused | ✅ |
| after `/newsession` and `/opensession` | record updated to the new file | ✅ |
| restart again | keeps the active session | ✅ |

Regression suites re-run on the same binary: error surfacing (§17.4, 6/6),
`/opensession` (11/11), dashboard renderer (`node ui.test.js`, 10/10).

## 18. Dashboard: resume, delete, descriptive tool rows (spec'd 2026-09-25, all three built)

Full spec, bug lists and test plans:
[`docs/spec-resume-session.md`](spec-resume-session.md).

### 18.1 Part B — descriptive tool rows (built 2026-09-25, Tier 1)

One plain-language line per tool call, in the *same* form live and after a
reload: `Running ls -la`, `Searching memos for “ssh access”`, with the tool name
as a small dim tag on the right and the exact call + result behind the toggle.

What was wrong and is now fixed (the L-list from the spec):

| # | Bug | Fix |
|---|---|---|
| L1 | live rows had no argument or detail — `toolcall_start` made the row with `null` and nothing ever filled it | the row is described at `toolcall_end` / `tool_execution_start` from the real `arguments`/`args`; until then it reads `Preparing <tool>…` |
| L2 | parallel calls shared one `curTool` pointer, so earlier rows pulsed forever and results landed on the wrong row | rows live in `toolRows` keyed by `toolCallId`, with a FIFO of rows whose `toolcall_start` carried no id; `settleToolRows()` on `agent_settled` ends anything still running |
| L3 | live wrote the result *into* the call row while a snapshot appended a detached `result` row | one row shape for both paths: labelled `call` + `result` sections, painted from `_args`/`_result` |
| L4 | the status dot was `content:"⏺"`, which iOS renders as an emoji that ignores `color` | the shared `.dot` CSS circle |
| L5 | large vertical gaps between consecutive tool steps | `margin:6px 0 8px` with `details.tool + details.tool { margin-top:2px }` |
| L6 | `session_messages()` (past transcripts) kept only `role` + `content`, dropping `toolCallId`/`toolName`/`isError`, so history could not pair results with calls | the daemon keeps the three fields on `toolResult` messages |

`describeTool(name, args)` is a pure function in `web/index.html` with the table
in one object literal (new MCP tools are one line each). Bash uses
`args.description` if a future Tier 2 supplies one, else the first command with a
leading `cd … &&` stripped and the text ellipsised at ~60 chars.

Tests, neither needing the daemon or the fake-pi harness:

```sh
node tests/describeTool.test.js   # ok — 47 describeTool cases passed
node tests/toolRows.test.js       # ok — 20 tool-row cases passed
```

`tests/describeTool.test.js` extracts the marked block from the page and runs the
§8.3 table (every row, plus `null`, non-string and empty args).
`tests/toolRows.test.js` drives the row events against a ~40-line stub DOM: three
parallel calls with results arriving in reverse order, an id-less
`toolcall_start`, one error among successes, and the same turn rendered live vs
from transcript messages. `UI_VERSION` → `2026-09-25.1`.

Not built: **Tier 2** (model-written bash descriptions — needs `pi.registerTool`
to be able to shadow the built-in `bash`, unverified), the iPhone-Safari
screenshot check (the dot is now a `background`-coloured element, so the emoji
failure mode is structurally gone), and the `describeTool` cases for tools not
seen in a real transcript. Parts A and C below are untouched.

### 18.2 Part A — resume a past session (built 2026-09-25)

Clicking a past session still *views* it; the banner now carries **▶ Resume**,
the only entry point, so what is being resumed is on screen before the user
commits. Sidebar clicks keep meaning "view".

What was wrong and is now fixed:

| # | Bug | Fix |
|---|---|---|
| B1 | `model_input` (does the current model see images?) was cached across a switch, so after one the vision auto-switch believed the old model's capability — and §2.4 says the model has just been reset underneath it | `_reset_run_state()` drops the cache, which every switch path calls, so the next image prompt re-queries |
| B2 | the model dropdown kept showing the model the user picked, not the one pi was actually on (§2.4) | `refreshHeader()` re-selects it from `/state`, adding the option if `/models` does not offer it |
| B3 | opening the session that was already live killed its running reply, *then* reported "already open" | the `get_state` + same-file comparison runs before `_abort_and_settle()` |
| B4 | `/opensession` checked only `isfile`, so an empty file became a new random-id session and a non-JSON one made pi throw | `_valid_session_file()` in the handler → 422 |
| B5 | resuming from `archive/` left the live session in `archive/`: listed twice, its session dir wrong, "Archive" on it a silent no-op, and the restart fallback never saw it | resuming un-archives it (`os.replace` into `sessions/`), reporting `unarchived: true`; a same-named file there is 409; a switch that fails or is cancelled moves it back. `renderSessions()` also drops `active` from *Archived* |
| B6 | `/sessions` flagged "active" by basename, so a name in both dirs was flagged twice | compares realpaths |
| B7 | resuming what a *second* tab was viewing left that tab in read-only mode on the live session | the `session_switched` handler returns that tab to live when `newFile` is the file it is viewing |
| B8 | a switch aborted a Siri/Matrix run, and `_reset_run_state()` cleared `busy` so the later `agent_settled` never settled it: the caller got nothing and timed out | the switch captures the waiting caller before the reset and delivers "⚠ Interrupted: the session was switched from the web dashboard." the way a give-up is delivered (result file or Matrix) |

**§2.4 checked live against real pi 0.87.1** (throwaway state dir, no fake):
started on the daemon's `--model` (`huggingface/zai-org/GLM-5.3-Flash`), set
`anthropic/claude-opus-4-5` via `/model`, then resumed another transcript. The
switch landed (`SESSION OPENED … new=…other.jsonl`) and `/state` went **back to
`huggingface/zai-org/GLM-5.3-Flash`**. The model a transcript was using is *not*
restored across a switch — B1/B2 were guarding a real reset. Re-applying the
user's choice after a switch is still a deliberate follow-up (see the spec's
§7).

T9 (the 3 MB, 16-image transcript) is **not** in the automated suite: it needs a
real model and a real context window. Not run here; it remains the one case that
must be checked by hand on a small-context model.

### 18.3 The harness finally exists

`tests/` is checked in (§5 step 0 of the spec, four sessions late). No
dependencies, no network, and **nothing touches the live agent**: every suite
starts a throwaway daemon with its own state dir, its own port, a loopback bind
and `tests/fakebin` first on `PATH`.

```sh
bash tests/run-all.sh
```

| Suite | Checks |
|---|---|
| `describeTool.test.js` | 47 — the §8.3 description table |
| `toolRows.test.js` | 20 — §8 rows against a stub DOM |
| `ui.test.js` | §17.4 error surfacing + T11/T12 (banner, resume, two tabs) |
| `opensession.test.sh` | 43 — T1–T8, T13, B6 |
| `errors.test.sh` | 6 — §17.4 regression |
| `resume.test.sh` | 11 — §17.7 / T10 restart resume |

The fake pi answers `get_state` (sessionFile, sessionName, model, messageCount),
`switch_session` (ok/fail/cancel/timeout), `set_model`, `abort`, `clear_queue`,
`get_messages`, and records **every** command it receives — so a test can assert
what the daemon did *not* do (no abort before the "already open" check, no
`switch_session` for an invalid target).

### 18.4 Part C — delete a session (built 2026-09-25)

A **Delete** button in the banner, next to Resume: the transcript you are
looking at is the one that goes, so it is never a guess. Soft delete — the file
is moved to `$AGENT_SESSION_DIR/trash/` and the janitor purges it after
`AGENT_TRASH_DAYS` (default 30). The daemon refuses the live session (409:
switch away first) and refuses while a switch is in progress, so a delete cannot
race an `/opensession` of the same file. `session_deleted` goes out over SSE; a
tab viewing that file returns to live.

**The purge had no owner and now does.** As flagged in §9.1's review: the
`janitor()` thread existed but only re-checked dispatch, `TRASH_DIR` was never
created and `AGENT_TRASH_DAYS` appeared nowhere in the code — so D6 could not
have passed and trash would have grown forever. `purge_trash()` now runs on the
same tick. Recovery before the purge is a plain `mv`; after it, the nightly
`/home/nuc` restic snapshot is the only copy left.

Attachments are **not** deleted, deliberately: `attachments/in|out|web-N…` are
keyed by request id, not by session (README says so), so deleting a transcript
leaves the pictures it referenced alone.

Tests: `tests/delete.test.sh` (D1–D6, D8, 24 checks) and the Part C sections of
`tests/ui.test.js` (the button, the confirm text, a refused delete, D7's
two-tab case). `AGENT_JANITOR_INTERVAL=1` keeps D6 to a couple of seconds.
Out of scope per the spec: bulk delete, an undelete UI, and auto-cleanup of
header-only empty sessions.

### 18.5 Build badge and versioning (built 2026-09-26)

Both halves of the dashboard now carry a version, and the page shows the pair at
the top right: `v2026-09-25.4 · 599cee9` (the commit is desktop-only — on a
phone the header already holds the toggle, the name, the status and the model).
Tapping it prints the whole string: dashboard version, daemon version and
commit, install time, and — when they differ — `⚠ dashboard and daemon differ —
restart the daemon`.

That last line is the point. Three times in this session the deployed page was
ahead of the running daemon (a Resume/Delete button against a build with no
`/deletesession` yet), and the only signal was a request that 404'd.
`DAEMON_VERSION` is bumped with `UI_VERSION`, `install.sh` records the git commit
in `$STATE/build.json`, and an older daemon with no `/version` at all reads as
*version unknown* rather than as a match.

**The bump rule: both numbers move together.** They identify one *deploy*, not
one file — `install.sh` installs the page and the daemon in the same breath, so
a daemon-only change bumps `UI_VERSION` too and the badge stays silent. Warn
only when the halves actually disagree, which means someone shipped one without
the other.

`GET /version` is a new endpoint rather than a field merged into `/state`,
deliberately: `/state` is a verbatim pass-through of pi's `get_state` and tests
assert on its shape, so the build info goes beside it, not inside it.

Tests: `tests/version.test.sh` (9 checks, including a missing `build.json` and
that `/state` gained nothing) and three cases in `tests/ui.test.js` for the
badge itself — matching, mismatched, and absent.
## 19. Always-on: the boot crash and the PATH trap (fixed 2026-09-26)


The service was already enabled and lingering, so "make it a service" needed no
work. Auditing it against `journalctl --user -u agent-session -b` turned up one
real outage:

```
Sep 21 11:07:26 debnuc agent-session-daemon[863]: FileNotFoundError:
    [Errno 2] No such file or directory: 'pi'
Sep 21 11:07:26 debnuc systemd[815]: agent-session.service: Main process
    exited, code=exited, status=1/FAILURE
Sep 21 11:07:32 debnuc systemd[815]: Scheduled restart job, restart counter is at 1.
Sep 21 11:07:33 debnuc agent-session-daemon[1490]: starting pi: … listening on FIFO
```

At boot the daemon could not find `pi` and died; six seconds later a graphical
login imported the real environment into the user manager, systemd retried, and
it came up. The agent was offline for those seconds and — with
`Restart=on-failure` and a start limit — could have stayed down.

Why: `pi` is `~/.local/bin/pi`. A `systemctl --user` unit started at boot with
linger gets systemd's **default PATH**, which has no `~/.local/bin`; the
manager only learns the login environment once a session imports it. Nothing in
the unit said so, and the daemon spawned a bare `"pi"`.

Fixes:

- `find_bin()` in the daemon resolves `pi` and `matrix-notify` by looking next
  to its own binary first (they are installed side by side in `~/.local/bin`),
  then `PATH`, then the usual bin dirs, with `AGENT_PI_BIN` as an override.
- `start_pi()` retries the spawn for ~8s before giving up, so a slow mount or an
  upgrade running under us no longer takes the service down at boot.
- The unit pins `Environment=PATH=%h/.local/bin:…` and switches to
  `Restart=always` with `StartLimitIntervalSec=0`, so it retries rather than
  giving up.
- `tests/service.test.sh` runs the daemon under `PATH=/usr/bin:/bin` in four
  layouts: side by side, `$HOME/.local/bin` only, `AGENT_PI_BIN` only, and
  nothing at all (where it must retry, then fail loudly).

Readiness is `/state`, not the unit's active state: it round-trips `get_state`
to pi, so a 504 means "up but not ready for chat".

## 20. The usage line: what the board shows, in the dashboard (built 2026-09-26)

`~/assistant/live-stats` already shows the DeepSeek account in a detail row at
the bottom of the panel — `$4.40 left · spent $5.51 of $9.91` — fed by
`bin/deepseek-usage`, which hits `api.deepseek.com/user/balance` with the key
from `~/.pi/agent/auth.json`. Only the balance is reachable: the token-usage
charts on platform.deepseek.com sit behind a browser session cookie and 404 for
an API key (checked 2026-09-21 in that repo's helper).

The dashboard now carries the same information, but built so a **provider change
does not break it**, which is the part live-stats' version cannot do:

- **Cost comes from the transcript, so it is provider-agnostic.** pi writes a
  `usage` block with `cost.total` and the `model` on every assistant message —
  verified across the live session (322 priced turns, $0.8416). `/usage` sums
  those, split into today and the session, plus input/output/cache tokens. No
  API key, no per-provider code; a session that spanned a model switch sums
  correctly because each message names its own model.
- **The balance is per provider and optional.** `AGENT_USAGE_CMD` (or an
  installed `agent-usage-<provider>` / `<provider>-usage`) is run on a slow
  clock and its JSON is passed through. No helper means no balance — the line
  says *balance unavailable* rather than inventing a figure, and the local cost
  stays. A helper that fails, or is missing, is reported and survived.
- The balance is dropped the moment the provider changes: another provider's
  balance is not a stale number, it is the wrong one.

Here `AGENT_USAGE_CMD` points at `live-stats/bin/deepseek-usage`, because that
repo already owns the helper *and* the `deepseek.topup_total` anchor it needs
(the API only reports what is left, so spend needs a baseline someone sets once
per top-up). Duplicating the script would mean configuring that anchor twice.

In the page it is one dim line above the composer, tapping gives the full
detail. `tests/usage.test.sh` (21 checks) covers the totals, the helper
contract, a helper that errors, one that is missing entirely, and the
provider switch.

## 21. The approval gate asked nobody (fixed 2026-09-26)

Two independent bugs made the gate deny every mutating call while showing no
question anywhere — and made read-only commands ask for permission they did not
need.

**1. Every bash command was gated.** `GATED_TOOLS = ["bash", "write", "edit"]`
with no inspection of the command, so `ls` and `cat` cost a keystroke.
`classify.js` now decides per command line: a table of readers (with the flags
that turn each into a writer — `sed -i`, `find -exec`, `sort -o`, `rg --pre`),
the mutators (anything that writes, escalates, executes, or leaves the box), a
subcommand allowlist for `git`, and **fail-closed** for anything unrecognised.
Every segment of `a && b | c` must be a read, and any `>` redirect makes it a
write. 123 cases in `classify.test.mjs`.

**2. The question could never arrive — twice over.**

*In the extension:* pi's RPC mode implements `ctx.ui.custom()` as
`async custom(){}` — a no-op that resolves immediately. The gate opened with
`await ctx.ui.custom(...)`, so in the web/Siri session it got `undefined`,
skipped its `catch` fallback (nothing threw), and fell through to
`block: "Denied by user (approval gate)"`. It never asked. The docs say to guard
terminal-only UI with `ctx.mode === "tui"`, which is what it does now, falling
back to `ctx.ui.select()`.

*In the daemon:* even had it asked, `extension_ui_request` was answered

```python
# A dialog with no timeout would hang the run forever; v1 auto-cancels.
self.send_cmd({"type": "extension_ui_response", "id": ev.get("id"), "cancelled": True})
```

— every select/confirm/input/editor cancelled on arrival, which is also why the
log only ever showed `notify` (that is the `/gate` command's own toast). The
daemon now relays: the request is broadcast over SSE as `ui_request`, the
dashboard answers at `POST /ui_response`, and the answer is forwarded to pi with
the same id. `GET /ui` lists anything still pending, so a reload can still
answer. Dialogs are cancelled when the run they belong to ends, a second tab
gets 409 rather than answering twice, and `_ui_watchdog` closes anything
unanswered after `AGENT_UI_TIMEOUT` (180s) — or after `AGENT_UI_NOUI_GRACE`
(15s) when no dashboard is connected, preserving the fail-closed behaviour the
old comment was reaching for.

Verified against **real pi**, not just the fake:

```
prompt: "Run exactly this shell command: ls /tmp"
  → questions asked: 0            (auto-approved, tool ran)
prompt: "Run exactly this shell command: touch /tmp/gate-e2e-probe"
  → GATE ASKED  "⚠️  Run shell command? $ touch /tmp/gate-e2e-probe  why ask: …"
     options: 1) Allow once  2) Allow for this session  3) Deny  4) Deny, but instead…
  → answered "3) Deny" → /tmp/gate-e2e-probe was NOT created
```

`tests/ui-relay.test.sh` (17 checks) holds the round trip permanently —
select/confirm/input, cancel, a second answer refused, the no-UI grace, and the
timeout.

Note: the extension lives in `~/.pi/agent/extensions/approval-gate/`, which is
**not under version control** — which is how a change this consequential sat
broken unnoticed. Moving it into a repo is an open follow-up.
