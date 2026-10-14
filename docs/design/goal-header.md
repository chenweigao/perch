# Goal beneath the conversation title

Kimi's session goal now occupies a compact, non-floating strip at the top of the
conversation content, below the session title. The composer retains its native
glass surface and no longer repeats the goal.

- Primary-colored objective, at most two lines when collapsed. Clicking it opens
  selectable full text in a bounded, scrollable region plus turns/tokens used.
- Activity uses the current main turn's running flag, not the goal's active flag.
  A paused goal can still show a spinner while its current turn finishes.
- Active goals offer Pause continuation; paused/blocked goals offer Resume goal.
  Complete/unknown goals do not offer a continuation action. Cancellation is in
  the overflow menu. These actions preserve drafts, attachments and permissions,
  and do not invoke Stop or send an extra model prompt.
- An offline or failed goal read displays Awaiting sync. Direct control is
  disabled until fresh state is available; online users can click to retry.
- Usage is descriptive, never an inferred completion percentage. Goal details
  reset on session or objective changes.

## Local review

Build the application with `bash scripts/build.sh`. After that,
`bash scripts/build-goal-preview.sh` builds `build/Perch Goal Preview.app`.
The preview uses the production GoalHeaderBar with isolated sample data, a sample
conversation shell, and controls for status, current-turn activity, offline state,
long objectives and dark mode. It neither loads nor changes real sessions.

ConnectionChecks covers draft/attachment preservation, duplicate-click exclusion,
no extra prompt/abort, stale-state gating and old-session action/error isolation.
The host lifecycle goal-header phase clicks the real expansion/pause controls and
checks collapsed/expanded geometry; it renders normal and narrow status fixtures.
WorkbenchChecks covers the supported status-to-continuation mapping. Live Kimi
service behavior is not established by these offline fixtures.
