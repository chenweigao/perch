# CI forensics — round-32 (PR #354)

## 6d11ec9 (settle, docs-only) — Bridge and acceptance contracts FAILED
Signature: portable suite `remote/test_claude_plan_worker.py` setUp ->
`self.wait('ready')` -> `queue.Empty` after 5s (224 tests, errors=1).
Runner-load startup-timing flake in the worker-readiness handshake; zero
relation to the docs-only diff. Same check GREEN on subsequent heads
(c38e85f, d19529f attempt-2, ec3111e runs).

## d19529f attempt-1 — Native host lifecycle regression (workspace) FAILED
Signature: `compiled/TaskContextReadingChecks.swift:61: Precondition failed`
(overview scroll offset expectation), phase `task-context` died ~1ms after
start (wait loops never engaged). The file has ZERO references to
ConversationSearch / the three caches (grep-verified); product delta
c38e85f->d19529f is the prefix-node cost formula only.
Same check GREEN at c38e85f (identical product path) and GREEN at d19529f
attempt-2 (same-head rerun, 15/15) => GUI flake family (round-30
navigation-disclosure precedent). Environment nondeterminism instance #25.
Job log excerpt saved as d19529f-hostws-fail.log.
