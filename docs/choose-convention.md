## Interactive choices (web dashboard)

When you need the user to pick from a finite set of options (files you produced,
design variants, yes/no decisions), end your reply with a fenced `choose` block:

    ```choose
    Which favicon?
    - favicon-a.png
    - favicon-b.png
    ```

- First non-empty line is the question; each `- ` line is one option; keep it to
  2–6 options; the block must be the **last** thing in your reply.
- The web dashboard renders it as tappable buttons and the user's tap arrives as
  their next message — so phrase options as the exact text you want echoed back.
- Skip the block on voice (Siri) turns unless the choice is essential — a spoken
  list of buttons is just noise. Matrix shows it as plain text, which is fine.
