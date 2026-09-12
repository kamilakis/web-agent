# Image input — constraints to design against

Notes for whoever plans the "send a photo from the phone" feature. Verified
against pi v0.85.1 source and the live daemon on 2026-09-11, not from memory.

## 1. The blocker: the session model is text-only

`/state` reports the live model as `deepseek/deepseek-v4-pro`, whose capability
list is `input: ["text"]`. Of the 20 configured models, these accept images:

| provider | models |
|---|---|
| anthropic | all 14 (fable-5/5-1, opus-4-5…4-8, opus-5, sonnet-4-5/4-6/5, haiku-4-5) |
| deepseek | `deepseek-v4-flash-vision-exp`, `deepseek-flash` |

The two failure modes are different, and neither is obvious from the outside:

- **User-attached images are not capability-gated.** In the openai-completions
  adapter a user message's content blocks are mapped straight to `image_url`
  with no `model.input.includes("image")` check, so the photo is sent to
  DeepSeek and the provider rejects the request. The person sees a failed run.
- **Tool-result images are gated** (`if (hasImages && model.input.includes("image"))`),
  so on a text-only model they are dropped in silence.

So the feature needs a model decision, not just plumbing: switch the session to a
vision model for the turn, or refuse the send with a clear message. The page
already has a model picker, so the honest cheap version is to block the attach
button with "current model can't see images" until one is selected.

## 2. Protocol: pi already accepts images

Both `prompt` and `steer` take an optional `images` array, each entry being
`{"type": "image", "data": "<base64>", "mimeType": "image/png"}`. Nothing needs
building on the pi side. Session history stores them as an `Attachment`
(`id`, `fileName`, `mimeType`, `size`, `content`, `extractedText`, `preview`).

## 3. What the daemon needs

- `web_prompt(message)` takes a string only; it needs an `images` parameter
  passed through into the `prompt` command.
- `POST /prompt` reads `body.get("message")` and ignores everything else.
- `self.rfile.read(n)` is unbounded. A phone photo is megabytes; cap the body
  and return 413 above the limit.
- **The FIFO cannot carry an image.** Its protocol is one line of
  `{"id":…, "prompt_b64":…}`, and `agent-task` is a shell script that shells the
  prompt in. A photo from Siri would need a different transport, not the FIFO.
- `send_cmd` writes one JSON line to pi's stdin while holding `stdin_lock`. A
  multi-megabyte line will block that lock until pi drains the pipe, stalling
  `/state` and every other command behind it. Worth a look under a slow send.

## 4. It breaks two things I just fixed — please keep them fixed

- **`/messages` snapshot.** The cap drops replayed `thinking` and truncates tool
  results, but knows nothing about images. Photos in history would be re-sent as
  base64 on every reconnect, which is exactly the 169 KB → 50.7 KB problem
  coming back an order of magnitude worse. Replace an image block's `data` with
  a placeholder, or a small thumbnail, before it leaves the daemon.
- **SSE broadcast.** `message_start` carries the whole message object, so a user
  message with an image pushes its base64 to every connected client through a
  200-slot queue. Filter image data out of broadcast events too.

## 5. iPhone specifics

- `<input type="file" accept="image/*" capture="environment">` opens the camera
  directly from Safari; no app, no shortcut.
- iPhone photos are HEIC. Safari usually converts on upload, but not always, and
  HEIC is not an accepted mime type upstream.
- Both problems disappear if the page downscales through a canvas before
  sending: long edge to about 1568 px (larger is scaled down anyway), re-encoded
  as JPEG. That also cuts a 4 MB photo to a few hundred KB, which makes the body
  cap, the stdin line and the SSE payload all comfortable.

## 6. The other routes, briefly

| route | what it needs | verdict |
|---|---|---|
| web composer attach | the daemon changes above, plus a client-side resize | **recommended** — one file, no new moving parts, works over WireGuard |
| Matrix | the listener drops anything that is not `m.text`; a photo is `m.image` with an `mxc://` URI needing an authenticated download | natural to use, but a new download path and credentials in the listener |
| iMessage relay | already a bridge on the Mac; attachments would need pulling off the relay | most moving parts, least control |
| Siri / Shortcuts over SSH | the FIFO cannot carry it (§3); would need a separate upload endpoint | awkward, and dictation is the point of that path anyway |
