# Compact activity and optional summaries

Perch folds consecutive tools, completed thoughts and runtime context into one
process region between user messages and visible agent commentary/replies. Expanding
preserves source order, including Bash, TodoList and edits. Live thinking stays
visible as a separate preview until that thought finishes. A pure thinking-only
response retains its existing presentation. Each region contains at most 24 process
records so expansion does not mount an unbounded view tree.

Collapsed regions show one line with the call count and up to two distinct recent
targets. Running calls, failed calls, missing results, disconnections and approvals
remain visible underneath. Completed calls stay in the disclosure. All process
headers use the same 12 pt arrow slot, 8 pt title gap and zero outer inset; only
expanded child records are indented. Adjacent process rows have a 6 pt gap while
body-message boundaries retain 18 pt spacing.

Filenames lead tool labels. Shell headers use the supplied description, or the
executable (`git` plus its subcommand); full commands remain in the tooltip and
input details. Status icons follow the label so Bash and Thoughts titles align.
Opening a single tool before more records arrive keeps its group expanded. The
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

Only the current user turn's recent process activity is eligible. Perch sends
up to 12 completed calls, with short tool names, filenames or search terms, IDs and their
reported outcome. For non-search tools only the tool name and optional filename
are included; shell arguments, edit contents, tool descriptions, runtime context,
user messages and reasoning are not sent. The service is asked to describe observed activity, not infer that
reading a file verified its correctness. `returned` is distinct from `succeeded`.

The first request requires six completed calls in a process region. Thoughts and
runtime context do not split the count or count as calls; two sets of three reads
separated by these records can trigger one summary. Other completed tool kinds
also count. The 24-record rendering limit starts another region. Later requests require
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
Activity row IDs use the first record's anchor without allocating arrays for the
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

- `swift run WorkbenchChecks` includes interleaved process grouping/order/identity, live/error
  preservation, summary opt-in, bounded inputs, update thresholds, request shape,
  credential exclusion and truncated-response checks.
- `scripts/build.sh` validates the complete macOS app. The existing reading,
  tool-visibility and navigation previews include the summary UI dependencies.
- `python3 scripts/check-scroll-following.py` checks the production scroll path
  after the macOS build. Check single-tool → group expansion, reading while new
  events arrive, and deferred summary publication in the native preview/app.
- `scripts/build-tool-visibility-preview.sh` includes a **交错过程记录** toggle
  mirroring the reported Thoughts → Bash → Thoughts → TodoList → three reads →
  Bash → runtime context → three searches → failed Bash sequence, plus a running
  read. With summaries disabled, verify the single-line header, deduplicated
  target, visible failure/live tool, aligned headers, and source order on expansion.
- Localization and public-source checks run on Linux as well as macOS.

Development verification on Linux does not establish SwiftUI rendering, Keychain
interaction, local-network permission prompts or Mac-to-LAN connectivity.
