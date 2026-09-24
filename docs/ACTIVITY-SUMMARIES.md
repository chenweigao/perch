# Activity narrative and completed-task Recap

Perch presents each turn as one activity narrative shared by the bottom activity
bar and the historical process rows. The narrative answers three questions without
requiring a second model call: what phase the agent is in, what it is working on,
and whether that stage is still updating or final.

The source priority is fixed:

1. provider-native summary metadata;
2. explicit agent commentary or progress;
3. optional external summary refinement;
4. deterministic local inference.

Native and local narratives are always available. External refinement is optional,
off by default, and can replace only a local narrative. It never overwrites provider
metadata or explicit agent progress.

## Stages and presentation

A stage has a stable ID derived from the turn and the event that opened it. Local
stages transition between exploring, editing, validating, integrating, blocked, and
mixed work. A first thought or first tool immediately gets a deterministic title;
provider summaries and explicit progress can supply a more precise title.

The transcript still limits each process disclosure to 24 records so expanding a long
turn does not mount an unbounded view tree. That rendering split does not create a
new semantic stage or change its ID. A tool phase transition, provider summary, or
explicit progress can open a new stage.

While a stage is open, the bottom activity bar is the only owner of its full headline.
The transcript removes the matching provider-summary or progress source row and keeps
tool rows as evidence (action, target, and status) without repeating the headline.
When the stage closes or another stage opens, its full headline is handed to exactly
one stable transcript anchor; supporting tool rows remain evidence-only. Ownership is
determined by stage and entry IDs, never by comparing rendered strings. After the turn
ends, the bar says that the turn ended instead of repeating the final historical stage.

Running, failed, missing-result, disconnected, and approval tools remain visible
under the process disclosure. Expanding preserves source order across thoughts,
tools, and runtime context. The narrative is presentation state only: it does not
change tool status, enter the agent context, or replace the final response.

Codex reasoning summaries arrive as structured `activity_summary` source metadata.
Perch uses only the provider-supplied summary parts for narrative text. Untagged private
thinking remains in the existing thinking view and is never treated as a narrative
source. Provider and progress text may be split deterministically at a short leading
clause: that clause becomes the headline, the remainder becomes detail, and trailing
colons are removed.

## Configure external refinement

External refinement uses one user-configured OpenAI-compatible Chat Completions
endpoint. No model is bundled, downloaded, selected, or paid for by Perch.

In **Settings → Interface → Activity narrative and Recap**:

1. Enter a **Base URL including `/v1`**, for example
   `http://localhost:8000/v1`, and the exact model name served by the endpoint.
2. Enter an API key if required. Perch stores it in the Mac Keychain, separately
   from endpoint preferences and conversation records.
3. For a Qwen service supporting `chat_template_kwargs.enable_thinking`, select
   **Disable Qwen thinking** to reduce latency and output overhead. Other services
   receive no Qwen-specific option unless selected.
4. **Test connection (send example)** sends a small synthetic sample. It can consume
   tokens but does not enable background requests or send conversation data.
5. Enable **external summary and Recap** and save.

Settings provides a direct **Disable** action without deleting the saved endpoint.
The endpoint must be reachable from the Mac; remote agent connectivity through SSH
does not make an arbitrary LAN endpoint reachable.

### HTTP IP endpoints on macOS

On macOS 14 and later, `NSAllowsLocalNetworking` alone does not cover HTTP
connections to IP literals. Perch's packaged `Info.plist` declares IPv4 and IPv6
CIDR exceptions (`0.0.0.0/0`, `::/0`) with
`NSExceptionAllowsInsecureHTTPLoads` for user-configured IP endpoints. These are
app-wide IP exceptions. DNS domains retain the existing ATS policy, including the
local-name exception. Perch does not add a global `NSAllowsArbitraryLoads`, disable
certificate validation, or ship a deployment address.

If the app reports that App Transport Security requires a secure connection, rebuild
and replace the installed app, then fully quit and relaunch it. `scripts/build.sh`
copies `Resources/Info.plist` into the app before signing. A command-line request does
not validate the packaged app's ATS policy.

## What external refinement receives

Only the current semantic stage of the current user turn is eligible. A request may
contain:

- the full current user text, preserving line breaks and excluding runtime-context parts;
- the last three public Agent progress/final text messages from that same turn;
- at most 12 activity records in source order, including running tools at stage start;
  up to three recent key results are retained even after many subsequent reads;
- a short tool name, record ID, reported status, and an explicit exit code when available;
- up to four trailing path components, or a bounded description, query, or pattern;
- a derived shell category such as `test`, `check`, `lint`, `build`, `read`, `wait`, or `git`;
- the current phase, closure state, and the previous summary from this stage or
  the preceding summarized stage in the same turn (including native summaries/progress).

Full command arguments, edit bodies/diffs, arbitrary tool inputs, private reasoning,
and runtime-context parts are not separately included. Public user/Agent text is
sent as written and can contain code or other sensitive content. Tool output stays
excluded by default. **Include tool output excerpts** opts into up to 600 characters
of text per result, keeping the beginning and end with an ellipsis when shortened.
Only string output or explicit `output`, `text`, `stderr`, or `stdout` text fields
are eligible; arbitrary output objects and images are not serialized.
The optional API key is sent only in the Authorization header. The response may
reference at most three known evidence IDs; unknown and duplicate IDs are discarded.

The service returns `subject`, one of the six valid phases, a compact `summary`,
`evidence_ids`, and `should_update`. Unknown structured phases are rejected. Plain
text remains accepted for compatibility and is assigned the mixed phase. A
`returned` status is not treated as verified success.

## Scheduling and failure behavior

A local stage becomes eligible at its first meaningful tool, even before completion.
It refreshes on a phase change, key result (such as an edit, test/build, or Git write),
failure/status correction, changed public progress, or closure. Repeated reads,
read-window eviction, shell setup, sleep, and empty terminal polls do not trigger
requests. Scheduling retains only key results within the 12-record prompt window plus an
identity/status fingerprint of earlier results. Payload corrections for shared
record IDs trigger updates; eviction alone does not. Stored batches and their
comparisons do not grow with stage history. A terminal poll with an explicit exit code is a result. Failures are never
suppressed as idle waiting. Provider-native and commentary stages retain priority
and do not create an external request.

All sessions share one worker. Requests are at least eight seconds apart globally;
pending observations coalesce to the newest eligible batch **after** throttling.
An in-flight response is not displayed if a newer event for that stage is pending.
When `should_update` is false, an existing refinement for the same stage is kept.
A new stage keeps its local headline instead of copying a prior stage already
shown in history; the prior summary still goes to the model as context.
Closure means observation ended, not that the task succeeded; the prompt distinguishes
`returned`, `succeeded`, and explicit exit codes.
There is no automatic retry, redirect, second model pass, or alternate-provider
fallback. A failure leaves the displayed narrative in place and exposes an explicit
retry. Configuration changes, disconnects and active-session changes cancel local
pending work but cannot undo tokens already processed by a server. Reconnecting can
retry an interrupted event; completed requests are not repeated solely by polling.

Opening an already-completed historical session does not trigger refinement: the
store must first observe that session running. Results are scoped by session and
stage. The shared store retains at most 64 session states and 256 external stage
results.

While the reader is away from the latest transcript position, already-published row
text and ownership state (anchor, open, or closed) stay frozen; new rows may initialize.
The deferred projection is published in one update when the reader returns to the
latest position. The bottom activity bar continues to show the live narrative while
the turn runs.

## Completed-task Recap

A completed Kimi or native-bridge task with no pending interaction exposes a compact
**Recap** action in the bottom activity bar. Generation starts only after the user opens
that popover; it never runs for an active task or merely because historical sessions
were loaded. The popover shows loading and retry states, a structured outcome, changes,
validation, remaining work and next steps, plus copy and regenerate actions.

Recap reuses the configured OpenAI-compatible endpoint but is independent from the
original Agent conversation. If the locally retained transcript is incomplete, Perch
reads older pages into a private copy without changing the visible transcript. It then
builds one bounded request from the complete history:

- the first turn and up to 11 most recent turns, using only public user and Agent text;
- up to 20 current Todo steps;
- up to 24 meaningful edit, write, shell, test, build, failure, or similar evidence
  records, with tool name, bounded target, status, and an exit code when available.

Runtime context, compaction summaries, private thinking, full shell arguments, and edit
bodies are excluded. Paths retain at most four trailing components. Tool output is
excluded by default; **Include tool output excerpts** opts into at most 600 characters
per selected result. The service receives no tools and cannot act on the Agent session.
There is no automatic retry, redirect, second pass, or provider fallback.

Successful results are cached locally by host, session, and completed-content revision.
The cache keeps 128 entries in
`~/Library/Application Support/dev.agentworkbench.mac/task-recaps.json`, uses atomic
writes and `0600` permissions, and is replaced when the user regenerates the same
revision. A cached Recap remains readable without reconnecting or calling the service.
Neither generation nor copying writes a message back to the Agent context.

## Session naming

The same endpoint can optionally generate a short local session title. **Name
sessions automatically** remains off by default and has no effect while external
refinement is disabled.

Only opened sessions with placeholder titles are eligible. A title supplied by the
agent or user is never replaced. Kimi sessions wait for the first turn to complete;
native bridge sessions may be named while that first turn runs. The request contains
only the opening of the first user message, at most 400 characters. Generated titles
never modify the remote session or enter agent context, and a later manual rename
wins. Naming gets one attempt per saved configuration revision and has no automatic
retry.

## Validation

- `swift run WorkbenchChecks` covers stage identity across 24-row rendering splits,
  phase transitions, source priority, Codex source decoding, event triggers,
  complete request/progress context, output opt-in, request shape, strict phase parsing,
  evidence filtering, plain-text compatibility, and Recap input bounds, privacy,
  request/response shape, cache capacity, revision identity, and file permissions.
- `python3 -m unittest discover -s remote -p 'test_*.py'` covers bridge event
  normalization, Codex streaming summaries, authoritative completion, and hydration.
- `scripts/build.sh` validates the complete macOS app.
- `python3 scripts/check-summary-lifecycle.py` checks the production queue with
  injected responses and isolated preferences: stage continuity, unchanged wording,
  burst coalescing, stale responses, turn isolation, disconnect and disable. It
  does not access the configured service, real credentials or remote agents.
- `scripts/build-activity-bar-preview.sh` provides commentary ownership/handoff,
  provider, local, external, failed external/retry, narrow-width, ended-turn, and
  disabled/loading/result/failure Recap fixtures without an agent connection.
- `scripts/build-tool-visibility-preview.sh` exercises transcript process grouping;
  its isolated defaults keep external refinement disabled.
- `scripts/build-tool-visibility-preview.sh --summary-duplicate` builds a separate
  native fixture using the production transcript and activity bar with an injected
  no-change model response. It checks active progress, the next stage, and turn end
  without SSH, Herdr, model network calls, or real credentials.
- `python3 scripts/check-scroll-following.py` checks the production scroll path after
  a macOS build.

Build, protocol, UI, remote compatibility, and performance evidence remain separate.
Linux or headless checks do not establish SwiftUI rendering, Keychain behavior,
local-network prompts, or Mac-to-LAN connectivity.
