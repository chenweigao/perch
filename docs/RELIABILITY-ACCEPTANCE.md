# Reliability acceptance

Keep four results separate: offline contracts, native interaction regression,
real agent recovery across two Macs, and calibrated frame measurements.
A passing build or synthetic bridge cannot certify the latter two.

## Repeatable offline checks

```sh
python3 scripts/check-functional.py portable --output .local/functional-portable
python3 scripts/check-functional.py macos --output .local/functional-macos
```

Use a new output directory for every attempt. Each command has a timeout;
failures stop the suite and retain the failed log and partial `results.json`.
There is no automatic retry or conversion of missing evidence into success.
The optional `WORKBENCH_LIVE_HOST` variable is removed from the suite environment.

- Portable: remote protocol and two-client recovery, installer, localization,
  and frame supervisor contracts. Uses Python's standard library. The recovery
  tests run the actual HTTP service and a synthetic OMP subprocess on loopback;
  they need permission to bind a local port but no agent installation or account.
- macOS: signed release build, WorkbenchChecks, ConnectionChecks, native composer,
  host lifecycle and scroll-following checks; then the production workbench with
  500 catalog entries and 200-turn histories. Covers search, switching, dashboard
  changes, and 60 seconds of combined streaming/draft/scroll input. The navigation
  fixture additionally reads all 200 turns and checks selection/anchors/roundtrip.
  Requires Xcode 27 and an active GUI session. GUI timings are local state/layout
  work, not hardware input latency or FPS.

The `Functional checks` workflow runs these suites on PRs and main, alongside the
existing publication checks, and retains logs/results for seven days. The Mac job
uses GitHub's [Xcode 27 preview image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
to match the local Swift 6.4 build. Its hosted GUI execution must be confirmed by
an actual workflow run; local equivalence alone does not establish hosted success.
`.github/actionlint.yaml` recognizes that official label until actionlint's built-in
runner list catches up. The label does not imply a self-hosted machine.

## What the two-client test establishes

`remote/test_client_recovery.py` starts a private service and synthetic RPC worker
in a temporary directory. Two independent HTTP connections exercise these paths:

1. A sends a prompt and disconnects without consuming the HTTP response. B reads
   the same running turn and its user echo. The worker completes after both
   connections close. A new connection reads the result and retries the original
   request ID; the worker has received exactly one prompt.
2. A disconnects with approval pending. B sees the unchanged request; no answer
   reaches the worker until B explicitly submits one. A stale second answer is
   rejected and is never delivered twice.
3. B begins another turn. A stale abort targeting the previous turn is rejected;
   stopping the current turn succeeds and does not increment completion count.

These are HTTP/service/worker contracts using the OMP adapter. They do not test
SSH tunnels, macOS sleep, real OMP or any other provider's runtime behavior.

## Two-Mac acceptance, when both devices are available

Use a new scratch directory and dedicated test session on the chosen remote host.
Record both app revisions, bridge version, agent CLI version, session ID and turn
ID. Keep endpoint tokens, credentials and real conversation content out of reports.
Run separately for each agent that will be relied on; do not infer Codex, Kimi,
Claude, Qoder or dsh recovery from the synthetic OMP result.

| Scenario | Required observation |
| --- | --- |
| Same remote session | Both Macs show the same session and latest messages; creating a second session with the same title does not count. |
| Disconnect while running | A disconnects/exits. B sees continued progress and the final result in the same turn. Closing A must not send abort. |
| Pending approval | A disconnects at an actual approval. B sees and answers that request once; reconnecting A shows the resolved state. |
| Continue and stop | B sends the next message in the same context, then stops its current turn. A refreshes to the same terminal state. |
| Response lost | After a confirmed transport interruption, reconcile the original request ID before retrying. A missing receipt stays unresolved; do not manually duplicate the message. |
| Sleep and wake | Repeat running and approval cases with A sleeping, then waking and reconnecting. Preserve reading position and unsent draft; no automatic resubmission. |

For each row record pass/fail/unverified, both clients' observations, and the exact
scope of any failure. Service/host crashes are a different contract: active work
may be interrupted, and old operations must not be automatically replayed. Do not
restart a shared service to test this; use an isolated runtime if it is needed.

## Frame calibration and long-session interaction

```sh
scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --capture frames --positive-control \
  --output .local/frame-control
python3 scripts/run-native-acceptance.py --capture frames --output .local/frame-baseline
```

Only interpret a baseline after a same-environment positive control detects the
intentional 120 ms stall as an app hitch. Empty frame tables, missing schemas,
unjoined app/frame events, failed behavior or a missed control fail acceptance.
A standalone baseline exit status only establishes usable captured data and
behavior; it does not establish that the hitch detector is calibrated or certify
smoothness. Do not replace failed frame capture with display-wide refresh counts.

On a real Mac, separately read an entire long conversation in both directions,
resize on a historical message, search/select Chinese and code text, switch away
and return, and type Chinese while replies stream. Check reading anchors, the
return-to-latest action, draft/marked-text preservation, visible content and CPU
settling. Record whether input was automated or a physical keyboard/trackpad.

For a longer offline run, after building the isolated app:

```sh
python3 scripts/run-native-acceptance.py --mode joint --seconds 1800 \
  --output .local/joint-30m
```

The synthetic stream deliberately bounds tail content. Its RSS/CPU measurements
cannot prove unbounded real histories are leak-free or that a real model is usable.
