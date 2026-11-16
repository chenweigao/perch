# CI failures at ded7cf1 (run 43882389531) — GUI runner-jitter family

Two jobs failed at ded7cf1 (round-30 v1 docs head; superseded by cf94157):

1. **Native session regression (streaming)** — `Failed native-dashboard: exited
   with code 1` with `TimeoutExpired` in the supervisor's `process.wait(timeout=95)`.
   GUI dashboard fixture process timeout.
2. **Native host lifecycle regression (workspace)** —
   `TaskContextReadingChecks.swift:61: Precondition failed` (SIGTRAP):
   `precondition(abs(reading.overviewOffset - 600) <= 2)` after an 80×25ms=2s
   wait loop — an NSHostingView/SwiftUI scroll-offset restoration assertion
   on a headless shared runner.

Execution isolation: the FAILING check (TaskContextReadingChecks, mode
'task-context') contains no reference to ConversationSearch /
ConversationEntryCache / RenderedSourceCache and exercises only SwiftUI
scroll-offset restoration; the HostLifecycleChecks target does contain
ConversationSearch usage in a DIFFERENT mode (ReadingDesignChecks), which
passed in this run. The round-30 product diff touches only the find-bar
search path; the native-dashboard failure is a supervisor process-wait
timeout, not an assertion. Signature matches the round-12 GUI-jitter family
(reading-design 60s / math app 180s / acceptance streaming 120s timeouts,
all judged shared-runner jitter with forensics).

Disposition: head advanced to cf94157 (v2 fixes) whose own CI run governs the
PR; no same-head rerun needed for ded7cf1. If the same GUI checks fail at
cf94157, rerun-failed + forensics per round-12/27 protocol. Gates never modified.

Aggregator job (133362608205) confirms the same two groups only:
BUILD/CORE/**MATH**/HOST_BUILD/ACCEPTANCE_BUILD/NAVIGATION(_BUILD) all
"success" — note the math ratio gate PASSED at ded7cf1 (v1 product bytes);
failed = {"host": TaskContextReadingChecks GUI precondition,
"acceptance": native-dashboard process timeout}. Single root-cause family,
head superseded by cf94157.
