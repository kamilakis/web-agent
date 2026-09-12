# Spec review — web-dashboard-spec.md (2026-09-11)

> **Round 2:** rev 2 of the spec resolved all 12 issues below, but the *built*
> daemon then showed five further defects (one destructive: every retry or
> compaction re-attributed a Siri/Matrix run to the web and dropped its answer).
> Those are fixed in the live daemon and documented in spec §13.

Checked against: the live `agent-session-daemon`, pi v0.85.1 `docs/rpc.md`, and
`dist/core/agent-session.js` (steer/abort/settled internals).

## Go or Python?

**Python.** The HTTP layer must live in the process that owns pi's stdin/stdout, so
"write it in Go" means rewriting the whole daemon (FIFO reader, Siri result files +
grace fallback, Matrix posting, task logs) — ~300 lines of proven code — to add
~250 lines of new code. Stdlib `ThreadingHTTPServer` + SSE is fine for one phone.

Go earns its place only if this becomes the general agent hub (attachments,
session switching, answering `extension_ui_request` dialogs, several clients).
If that day comes, rewrite the daemon in Go in one go; `bufio.Scanner` is
JSONL-compliant (LF only) out of the box.

## Bugs / gaps in the spec, most serious first

1. **busy-flag race → steer swallowed by the NEXT Siri prompt.**
   pi sets `_isAgentRunActive=false` *before* it writes the `agent_settled`
   line; the daemon's `busy` stays True until that line is read. A `/prompt`
   in that window sends `steer` to an idle pi, and `_queueSteer` just pushes
   it into `agent.steer(...)` — it is glued onto whatever prompt runs next
   (possibly a Siri one). Fix: always send
   `{"type":"prompt","message":…,"streamingBehavior":"steer"}` and let pi
   decide atomically; derive `busy` from `agent_start`/`agent_settled` events,
   not from the daemon's own guess.

2. **A rejected prompt wedges the daemon forever.** `web_prompt` sets
   `busy=True` then sends; if pi answers `response success:false` (agent
   streaming, compacting, extension command…) nothing resets `busy`, and
   FIFO dispatch stops. Existing daemon has the same hole; the web path makes
   it reachable. Route `response` events for `web-*`/`fifo-*` ids: on
   `success:false` clear busy, log, `maybe_dispatch()`.

3. **Token scheme contradicts itself.** `EventSource` cannot send an
   `Authorization` header (the risks table says "use the header instead"), and
   `self.path == "/events"` never matches `/events?token=…`. Use
   `urllib.parse.urlsplit`, accept `?token=` (or a cookie) on `/events`, and
   make every frontend `fetch` send the header.

4. **`cmd_seq` incremented without a lock** in `send_cmd_with_response` — two
   HTTP threads can mint the same rid and one waiter times out. Bump it under
   `pending_lock`.

5. **SSE has no heartbeat.** `q.get()` blocks forever; a phone that drops off
   WG is never detected (thread + queue linger until the queue fills). iOS
   Safari also kills silent streams. Use `q.get(timeout=15)` and write
   `: ping\n\n` on timeout. The "survives the WG link via keep-alive" claim is
   false as written.

6. **Frontend `provider` is undefined** in `modelSel.onchange`. Put
   `provider/modelId` in the option value (or data-attrs) and split it.

7. **Joining mid-stream crashes the renderer.** After reconnect (or first load
   while pi is streaming) the first `message_update` arrives with no
   `curMsg`. Create the bubble lazily on any delta. Also `/messages` omits the
   in-flight message, so the partial text is lost until `message_end` —
   acceptable for v1, say so.

8. **Responses are routed by the event thread, which `settle()` blocks.**
   `post_matrix` can take up to 20 s inside `read_events`; meanwhile `/state`
   waits and times out at 15 s. Post to Matrix from a thread (the Siri grace
   path already does). Also: `web_prompt` calls `send_cmd` while holding
   `self.lock` — release it first.

9. **Task log says `delivered: matrix` for web runs.** `write_task_log` is
   called with `"spoken" if pid else "matrix"`; add a `"web"` value. And
   `Handler.d` is never wired — set it as a class attribute before
   `ThreadingHTTPServer(...)`.

10. **Stop doesn't clear the daemon's own FIFO backlog.** `clear_queue` empties
    pi's steer/follow-up queue only; after `agent_settled` the next queued
    Siri/Matrix prompt dispatches immediately. Probably intended — document it.
    Note also: aborting a Siri/Matrix run posts the truncated answer to Matrix.

11. **`extension_ui_request` dialogs hang the run.** pi blocks until a client
    answers; the daemon never does. Out of scope, but log them now and treat
    the web UI as the v2 place to answer them.

12. **`get_messages` grows without bound.** The session file is 592 KB after
    one day; every reconnect re-fetches the whole transcript over WG on a
    phone. Cap the snapshot server-side (last N messages) or strip tool
    results.

## Confirmed OK

- `abort` → `waitForIdle` → `agent_settled` still fires, so `settle()` runs.
- A steer queued during a run is consumed before `agent_settled`, so the
  one-settle-per-prompt assumption holds.
- `<wg-ip>` is wg0's address; port 8383 is free.
- Python's text-mode line iteration splits on LF/CR only (not U+2028), so
  the daemon's reader is framing-compliant.
