# Compact activity and optional summaries

Perch groups adjacent read/search calls in the transcript. Tool inputs and outputs
remain available in source order. Running calls, failed calls, missing results,
disconnections and approvals remain visible when the group is collapsed. A group
contains at most 24 calls so expanding a long run does not mount an unbounded view.
Progress text, user guidance, edits and other tool kinds keep separate boundaries.

Filenames lead tool labels; full paths remain in the tooltip and input details.
Opening a single tool before more calls arrive keeps its group expanded. The
composer owns the stop button; unavailable thinking-effort settings are explained
inside the model selector rather than occupying the composer toolbar.

## Configure a summary service

Activity summaries are **off by default**. No model is bundled or downloaded and
Perch does not choose a paid service. Basic grouping works without a summary model.

In **Settings → Interface → Configure activity summaries**:

1. Enter a Chat Completions-compatible **Base URL including `/v1`**, for example
   `http://localhost:8000/v1`, and the exact model name served by your endpoint.
2. Enter an API key if the service requires one. Perch stores it in the Mac's
   Keychain, separately from endpoint preferences and conversation records.
3. For a Qwen service that supports `chat_template_kwargs.enable_thinking`, select
   **Disable Qwen thinking**. The request then explicitly sets this value to false.
   Other services receive no Qwen-specific option unless selected.
4. **Test connection (send example)** sends a small synthetic sample. This can
   consume tokens even while background summaries are disabled; it does not enable
   the feature or send your conversation.
5. Enable activity summaries and save. The endpoint must be reachable from the Mac;
   remote agent connectivity through SSH does not make an arbitrary LAN endpoint
   automatically reachable.

Endpoint and model fields have no built-in LAN address or credential. A self-hosted
LAN deployment uses the same configuration path as any other compatible service.
Settings provides a direct **Disable** action without deleting the saved endpoint.

## What is sent and when

Only the current user turn's recent read/search activity is eligible. Perch sends
up to 12 completed calls, with short tool names, filenames or search terms, IDs and their
reported outcome. Source contents, tool output, user messages and reasoning are
not included. The service is asked to describe observed activity, not infer that
reading a file verified its correctness. `returned` is distinct from `succeeded`.

The first request requires six completed calls in a group. Later requests require
six new completed calls, a correction to an included event, or changed records
when that group closes. Requests start at least 15 seconds apart within the
selected transcript, with only one in flight. Pending changes coalesce to the
most recent eligible batch. Inputs have per-field and event-count bounds; output
uses `max_tokens: 120`. These bounds are not a tokenizer-accurate input-token cap.

Generated text is labelled as a summary and stored only in the transcript's
presentation state. It is not injected into the agent's context, used for tool
status, or substituted for the final response. While the reader is scrolled up,
new summary text is held until they return to the latest activity.

Disabling the feature, switching configuration or leaving the transcript cancels
local pending work. It cannot undo tokens already processed by the server. No
automatic retries, redirects or alternate provider calls occur. A failed or
truncated response leaves the rule-based group available. Historical sessions
opened after completion are not automatically summarized. Native preview and
benchmark fixtures cannot invoke the configured service.

## Performance

Disabled summaries, preview fixtures and disconnected transcripts skip summary
candidate lookup and label construction. When enabled, lookup walks backward from
the transcript tail and stops at the first eligible group or the user boundary;
it does not first scan the entire current turn to locate that boundary.
Activity row IDs stop at the first tool ID without allocating arrays for the
whole group. Identical summary text does not publish another transcript update.
Displayed summaries retain text only; request deduplication retains the attempted
batches separately. Both caches last for the selected transcript and grow with
summarized groups; this is not a constant-memory cache.

These changes remove specific CPU/allocation work, but are not measured frame-time
improvements. The remaining native profiling priorities are transcript projection
and row reconciliation during streaming in long histories, and height changes when
a new summary arrives. Validate with summaries off/on using the same history,
event stream and viewport on macOS before changing cache or rendering architecture.

## Validation

- `swift run WorkbenchChecks` includes grouping/order/identity, live/error
  preservation, summary opt-in, bounded inputs, update thresholds, request shape,
  credential exclusion and truncated-response checks.
- `scripts/build.sh` validates the complete macOS app. The existing reading,
  tool-visibility and navigation previews include the summary UI dependencies.
- `python3 scripts/check-scroll-following.py` checks the production scroll path
  after the macOS build. Check single-tool → group expansion, reading while new
  events arrive, and deferred summary publication in the native preview/app.
- Localization and public-source checks run on Linux as well as macOS.

Development verification on Linux does not establish SwiftUI rendering, Keychain
interaction, local-network permission prompts or Mac-to-LAN connectivity.
