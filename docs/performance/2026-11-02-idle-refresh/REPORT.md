# Herdr idle refresh: socket executor and catalog invalidation

Initial base: `4967f6483202a3b9635fa84fb2fdc72bf8dcb5e1`.
Rebased without conflicts onto `79a696c` (origin/main); its changes concern UI
corner-radius tokens. Release build and checks were repeated after rebasing.
Build/check host: macOS 27.0.1 (26A434), arm64, Apple Swift 6.4.0.34.1;
Swift language mode 5 and macOS 26 minimum remain unchanged.

## Evidence

The supplied sample is `perch_sample.txt`, MD5
`e86be98da7c693791f8fa34eb63bd7a3`, captured 2026-11-02 19:44:45 +0800
from Perch 0.5.0 (928), PID 10646. It records footprint 336.4 MB and peak
522.0 MB. The raw sample is not committed.

- Lines 5422–5447: the cooperative queue has 298 samples in synchronous socket
  `read` and one in `Wire.decode`. These are waiting-stack observations, not
  299 samples of CPU execution or proof of executor starvation.
- Lines 4402–4412: 163 main-thread samples pass through
  `HostConnection.refresh → snapshotUpdated`; 137 enter `catalogChanged`,
  133 enter `rebuildCatalog`, including 86 in ISO8601 date parsing. Current
  source calls this callback after every successful three-second Herdr poll,
  even when the decoded snapshot is unchanged.
- SwiftUI rendering and localization stacks are present. The sample alone does
  not establish a missing cache, per-frame full redraw, WebSocket message rate,
  WindowServer causality, or absence of memory leaks.

A separate five-second sample on this Mac mini was from build 927 (PID 21873),
with 133.6 MB footprint and 227.3 MB peak, and did not reproduce those stacks.
It is not a matched baseline for build 928. No running application was quit or
replaced. Display/window geometry and original session inputs were not captured.

## Changes

`JSONSocket.request` is async and suspends its caller while a dedicated concurrent
Dispatch queue performs the existing Unix socket protocol. Blocking connect,
write, and read no longer execute on a cooperative worker. Framing, errors,
receive/send timeouts and descriptor cleanup remain in the synchronous helper.
Cancellation is checked before and after I/O; an in-flight operation still waits
for I/O completion or the existing socket timeout. This is not immediate socket
cancellation or a new end-to-end deadline.

Snapshots and their component models gain value equality. `HostConnection` only
publishes a snapshot and invokes its catalog callback when content changes;
reconnection still invokes the callback. Successful polls retain freshness
updates, and error clearing remains active. Decoding stays off the main actor.
This removes redundant catalog rebuilds; it does not eliminate polling or all
UI updates, and it does not introduce localization/render caches.

## Validation

- `./scripts/build.sh`: PASS, Release app produced at `build/Perch.app`.
- `codesign --verify --deep --strict build/Perch.app`: PASS (local ad-hoc signing).
- Release `WorkbenchChecks`: PASS, 77 PASS records. Read-only live SSH check
  skipped because `WORKBENCH_LIVE_HOST` was unset.
- Release `ConnectionChecks`: PASS, 56 PASS records. New Herdr fixture verifies
  20 unchanged snapshots cause zero additional snapshot publications/catalog
  callbacks; metadata changes, removal and reconnect remain observable.
- `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 WORKBENCH_BENCH=json-socket
  .build/arm64-apple-macosx/release/WorkbenchChecks`: PASS. A real Unix peer waits
  for the async consumer to observe its request before replying. Checks cover
  fragmented newline framing, request parameters, cooperative progress,
  cancellation, peer EOF and descriptor cleanup.
- Negative control: an isolated copy of the socket fixture and production socket
  source, with the queue/continuation bridge replaced by a direct blocking call,
  fails the peer's five-second executor-progress assertion under the same strict
  pool setting (exit -5). Only error/localization plumbing is stubbed in this
  standalone harness. This validates the scheduling test, not UI frame timing.
- `git diff --check`: PASS.

Local logs and the negative-control harness are in `.local/idle-refresh/`.
No measured whole-app CPU reduction, WindowServer A/B, installed-app acceptance,
live SSH acceptance, push, PR, merge or deployment is claimed.
