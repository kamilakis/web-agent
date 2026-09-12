# Spec review — Qwen/Qwen2.5-72B-Instruct

model: Qwen/Qwen2.5-72B-Instruct | tokens: prompt=11361, completion=2116

### Review Findings

#### Blocking Issues

1. **§3 Run-state model:**
   - **Issue:** The `pending` flag is set to `False` in the `settle` function, which can lead to a race condition if a new prompt is dispatched while the `settle` function is running.
   - **Fix:** Ensure that the `pending` flag is only cleared after the `busy` flag is set to `False` and all other state changes are committed.
   - **Section:** §3, §4.3

2. **§4.3 `read_events()` additions:**
   - **Issue:** The `on_prompt_rejected` function is called on a worker thread, but the `pending` flag is not cleared in the main thread, which can lead to a race condition.
   - **Fix:** Ensure that the `pending` flag is cleared in the main thread after the worker thread completes.
   - **Section:** §4.3

3. **§14.4 Backend changes:**
   - **Issue:** The `web_prompt` function does not handle the case where the current model is a vision model but the user tries to send a text-only prompt. This can lead to unexpected behavior.
   - **Fix:** Add a check in `web_prompt` to ensure that if the current model is a vision model, the user can only send prompts with images.
   - **Section:** §14.4

4. **§15.4 Daemon changes:**
   - **Issue:** The `settle` function scans the `current_out_dir` for new files, but it does not handle the case where the directory is empty or the files are not images.
   - **Fix:** Add a check to ensure that only image files are processed and broadcasted.
   - **Section:** §15.4

5. **§15.6 Security:**
   - **Issue:** The path traversal guard in the `/media` endpoint is not robust enough. It only checks if the path is within the `ATTACH_DIR`, but it does not handle symbolic links or other forms of path manipulation.
   - **Fix:** Use `os.path.abspath` and `os.path.realpath` to ensure that the path is fully resolved and does not contain any symbolic links.
   - **Section:** §15.6

#### Minor Issues

1. **§3 Run-state model:**
   - **Issue:** The `current_source` is set to `"web"` in the `settle` function when a run is not dispatched, but this can lead to incorrect attribution if the run was actually started by another source.
   - **Fix:** Ensure that the `current_source` is only set to `"web"` if the run was explicitly started by the web interface.
   - **Section:** §3

2. **§4.4 SSE server:**
   - **Issue:** The `broadcast` function does not handle the case where the `clients` list is modified while the function is running, which can lead to a `RuntimeError`.
   - **Fix:** Use a copy of the `clients` list to avoid modifying the list while iterating over it.
   - **Section:** §4.4

3. **§5.3 Live events:**
   - **Issue:** The `ensureCur` function is called in multiple places, which can lead to redundant code.
   - **Fix:** Refactor the code to call `ensureCur` in a single place to ensure consistency.
   - **Section:** §5.3

4. **§14.3 Frontend changes:**
   - **Issue:** The image preview pill is not removed if the user cancels the image selection.
   - **Fix:** Add an event listener to the file input to remove the preview pill if the user cancels the selection.
   - **Section:** §14.3

5. **§15.5 Frontend changes:**
   - **Issue:** The `web_attachments` event handler does not handle the case where the token is missing or invalid.
   - **Fix:** Add a check to ensure that the token is valid before rendering the images.
   - **Section:** §15.5

#### Correct Sections

- **§1 Language decision: Python (not Go)**
  - **Review:** Correct. The reasoning for using Python is sound, and the implementation details are consistent with the decision.
  - **Section:** §1

- **§2 Architecture**
  - **Review:** Correct. The architecture is well-defined and consistent with the goals of the project.
  - **Section:** §2

- **§4.1 Thread-safe command I/O**
  - **Review:** Correct. The use of a lock to ensure thread-safe command I/O is appropriate.
  - **Section:** §4.1

- **§4.2 Request/response correlation**
  - **Review:** Correct. The implementation of request/response correlation is robust and handles timeouts appropriately.
  - **Section:** §4.2

- **§4.5 Broadcast**
  - **Review:** Correct. The broadcast function is correctly implemented to handle multiple clients and avoid blocking.
  - **Section:** §4.5

- **§4.7 Config (env vars, daemon defaults)**
  - **Review:** Correct. The configuration variables are well-defined and the default values are appropriate.
  - **Section:** §4.7

- **§5.1 Auth**
  - **Review:** Correct. The token handling is consistent with the security requirements.
  - **Section:** §5.1

- **§5.2 Startup**
  - **Review:** Correct. The startup sequence is well-defined and handles errors appropriately.
  - **Section:** §5.2

- **§5.4 Controls**
  - **Review:** Correct. The control handling is consistent with the expected behavior.
  - **Section:** §5.4

- **§6 systemd**
  - **Review:** Correct. The systemd configuration is appropriate and does not require changes.
  - **Section:** §6

- **§8 Test plan**
  - **Review:** Correct. The test plan is comprehensive and covers all the necessary checks.
  - **Section:** §8

- **§9 Risks & mitigations**
  - **Review:** Correct. The risks are well-identified, and the mitigations are appropriate.
  - **Section:** §9

- **§10 Out of scope (future)**
  - **Review:** Correct. The out-of-scope items are clearly defined, and the reasoning is sound.
  - **Section:** §10

- **§11 Files touched**
  - **Review:** Correct. The list of files touched is accurate and consistent with the changes described.
  - **Section:** §11

- **§12 Review resolutions**
  - **Review:** Correct. The resolutions to the review issues are well-documented and appropriate.
  - **Section:** §12

- **§13 Rev 3 resolutions (defects found in the built daemon)**
  - **Review:** Correct. The defects are well-documented, and the resolutions are appropriate.
  - **Section:** §13

- **§14.1 Model constraint**
  - **Review:** Correct. The model constraint is well-defined and consistent with the capabilities of the vision models.
  - **Section:** §14.1

- **§14.2 Flow**
  - **Review:** Correct. The flow for image input is well-defined and consistent with the implementation.
  - **Section:** §14.2

- **§14.5 Snapshot / reconnect**
  - **Review:** Correct. The handling of snapshots and reconnects is well-defined and appropriate.
  - **Section:** §14.5

- **§14.6 Other surfaces**
  - **Review:** Correct. The handling of other surfaces (Matrix, Siri) is well-defined and consistent with the scope of the project.
  - **Section:** §14.6

- **§14.7 Risks**
  - **Review:** Correct. The risks are well-identified, and the mitigations are appropriate.
  - **Section:** §14.7

- **§15.1 Scope and honest boundaries**
  - **Review:** Correct. The scope and boundaries are well-defined and consistent with the capabilities of the system.
  - **Section:** §15.1

- **§15.2 The two gaps to close**
  - **Review:** Correct. The gaps are well-identified, and the solutions are appropriate.
  - **Section:** §15.2

- **§15.3 Flow**
  - **Review:** Correct. The flow for image editing is well-defined and consistent with the implementation.
  - **Section:** §15.3

- **§15.7 Config**
  - **Review:** Correct. The configuration variables are well-defined and appropriate.
  - **Section:** §15.7

- **§15.8 Out of scope / future**
  - **Review:** Correct. The out-of-scope items are clearly defined, and the reasoning is sound.
  - **Section:** §15.8

- **§15.9 Build steps**
  - **Review:** Correct. The build steps are well-defined and appropriate.
  - **Section:** §15.9

- **§15.10 Test plan**
  - **Review:** Correct. The test plan is comprehensive and covers all the necessary checks.
  - **Section:** §15.10

- **§15.11 Risks**
  - **Review:** Correct. The risks are well-identified, and the mitigations are appropriate.
  - **Section:** §15.11

### Summary

The spec is generally well-written and comprehensive, with clear and consistent implementation details. The blocking issues identified should be addressed to ensure correctness and robustness. The minor issues are also important to address for a polished and reliable implementation.