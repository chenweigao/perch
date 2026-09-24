# Reliability acceptance and functional CI — 2026-09-24

This change adds repeatable offline recovery/interaction checks and CI. It does
not change production UI or agent behavior, establish real two-Mac recovery, or
claim smoother rendering. Product source is the `5639c04` baseline; test and
workflow changes are fingerprinted in `measurements.json` (the original local run).

## Recovery coverage

Two new tests run the real HTTP bridge and a synthetic OMP subprocess, with two
independent clients. They verify a lost prompt response followed by receipt/history
recovery, completion after disconnection, exactly one worker prompt after retry,
pending approval transfer with exactly one answer, and stopping only the current
turn without counting it as another completed result. Both passed. The full bridge
suite passed 94 tests. Installer tests passed 6, localization tests 4, and frame
supervisor contracts 6; the localization coverage check also passed.

This is a loopback transport/service test, not two physical Macs, SSH, sleep/wake,
or a real model. The second Mac was offline. The provider-specific two-Mac matrix
remains **unverified**; see [the runbook](../../RELIABILITY-ACCEPTANCE.md).

## Functional CI and failures found while integrating it

The new workflow runs portable tests and the native Mac suite separately, retains
logs on failure, and uses bounded subprocesses without automatic retries. Local
commands are the same as CI. The original local record predates pushing this change;
hosted execution is tracked separately in [PR #46](https://github.com/chenweigao/perch/pull/46).
GitHub's Xcode 27 preview image and GUI behavior remain a separate hosted acceptance
boundary. Actionlint 1.7.12 validates the workflow with the
documented official runner label added to its local label list.

The first Mac suite stopped at ComposerChecks with exit 137. Bare and directly
shell-launched signed binaries were killed before test output; repackaging alone
was not a reliable fix. A same-binary comparison returned SIGKILL through a shell
and passed through Python's direct subprocess launch. The final script uses a
fresh isolated signed app and the Python launch pattern already used by host
lifecycle checks, with a 30-second timeout and a final receipt after all assertions.
It does not retry. The exact macOS termination mechanism was not established.

A later run passed ComposerChecks but caught an intermittent host-fixture failure:
the restart phase loaded no pinned session. `finishSetup`/`showHome` enqueue an
asynchronous workspace save, while the seed phase wrote its restart fixture directly
to the same path. The queued empty save could overwrite the fixture. The seed now
calls the existing shutdown/flush path before installing that fixture. Assertions
are preserved, with an explicit single-pin precondition before indexing. This is
a test-ordering repair, not a production persistence fix.

All failed attempts remain in `.local/reliability/` (`macos`, `macos-bundled`,
`macos-final`, and composer probe logs); they are not counted as passing runs.
The final aggregate run is `macos-verified`; its per-check results are retained in
`measurements.json`. Original logs and granular native/navigation receipts remain
under `.local/reliability/macos-verified/`.

The final run passed all 16 stages: production build/signature, WorkbenchChecks,
ConnectionChecks, composer, host lifecycle, scroll following, acceptance build,
production-workbench all/switching/dashboard/joint scenarios, navigation build,
and full-history reading/interactions/roundtrip. The switching scenario verified
80 switches; the 60.26-second joint scenario verified 148 updates and 8 switches.
Publication tests passed 17 checks. All 16 selected offline stages ran; the optional
live SSH check remained disabled by design.

The first hosted Linux attempt exposed an existing test-module lifecycle error:
`test_native_service.py` registered its temporary-directory cleanup during import.
Python 3.12 runs module cleanups after the preceding recovery-test module, deleting
the runtime before the native-service tests start. Python 3.9's teardown behavior
had masked this locally. The runtime is now created in `setUpModule` and removed
in `tearDownModule`, with its environment override scoped to the service import.
The full portable suite passed locally on both Python 3.9 and 3.12 after this fix.
Hosted results on the latest PR revision are the authoritative CI outcome; the
original failed run is retained rather than counted as a pass.

The next hosted run passed portable checks and the first 12 Mac stages, then
failed building Navigation Preview because the runner did not have ripgrep.
The build script now enumerates object files with system `find`, removing the
undeclared tool dependency. Full-history checks remain enabled.

## Frame calibration remains unverified

The isolated Xcode 27 / Swift 6.4 acceptance app ran a known 120 ms main-thread
stall. Behavioral assertions passed and Instruments exported the requested schemas,
but `hitches-updates`, `hitches`, `hitches-frame-lifetimes` and
`display-vsyncs-interval` each contained zero rows. The summarizer rejected the
capture, and the supervisor returned exit 1. No baseline or FPS conclusion was
derived from it.

The supervisor now explicitly requires verified app frame events in its final
pass condition as well. Six contract tests cover unverified events, missing
schemas, missed/detected control, a usable baseline and failed behavior. This is
an explicit acceptance invariant; the observed empty-table capture already failed
through the summarizer's error exit, so it is not evidence of a previously passing
empty capture.

Native and navigation replay timings measure programmatic state/layout/display
work. They do not measure physical trackpad inertia, hardware IME latency or
frame presentation. No new 30-minute soak, real-model run, two-Mac run or physical
trackpad acceptance is claimed in this report.
