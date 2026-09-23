# Session switching hang (2026-09-23)

The affected Mac app stayed near one full CPU core after a session switch.
Two live samples (5 s and 3 s) put 97–98% of main-thread samples in SwiftUI
view transactions, with `LazySubviewPlacements`, `LazyStack.place`, and
`ForEach<WorkspaceSession>` on the hot paths. Runtime logs also reported
recursive AppKit layout, state publication during view updates, and repeated
`onChange` updates for `KimiSession` and `SummaryObservation`.

## Change

- Use an eager stack for the sidebar navigation list (recents are capped at
  20). This removes lazy placement/height estimation from the observed hot path
  while preserving scrolling, row identity and the separate full session list.
- Schedule Kimi and native completion-review callbacks with `.task(id:)`.
  These callbacks publish workspace/catalog changes, so they must not run
  synchronously inside an `onChange` view-update callback. Kimi's identity uses
  the session ID and the same completion timestamp saved by `markReviewed`.

## Regression

```sh
./scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --mode switching --output .local/switching-check
```

The isolated production workbench uses 500 catalog entries and eight resident
200-turn conversations. It switches 80 times while changing sidebar row
heights/order and adding/removing favorites. Every switch checks the selected
transcript and visible draft, then checks that idle CPU settles. The existing
120-step history scroll/host-retention check runs afterward. A separate process
supervisor bounds execution so a blocked main actor cannot hide a hang.

The initial fixed run passed all 80 switches; idle CPU was 0.082 CPU-seconds over
2 wall-clock seconds. WorkbenchChecks, ConnectionChecks and a signed release
build also passed. The automated live SSH check was skipped because
`WORKBENCH_LIVE_HOST` was unset.

After rebasing onto `938b290` (the newer composer and naming changes), the same
80-switch regression passed again, with 0.123 CPU-seconds over the idle 2-second
window. Neither fixed acceptance run logged the three runtime diagnostics
listed above. Timings include local decode/layout and fixture work, not network
latency or hardware input latency.

These synthetic transitions exercise the affected layout, but do not reproduce
the exact original remote event sequence or prove a zero recurrence rate.
The release was installed locally after backing up the previous app and saved
workspace. Three real Kimi switches (including returning to the original
running session) restored the correct transcript and editable composer. No
matching recursive-layout/state-publication diagnostics appeared during that
check. These were running sessions: completion-review behavior was not directly
accepted against a newly completed remote session; the offline switch fixture
synthesizes catalog changes directly.
