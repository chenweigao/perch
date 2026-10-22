# Perch workspace upgrade

User approved all six directions on 2026-10-22. Baseline: d716933.
Implementation stays on feat/workspace-upgrade-20261022 in its dedicated worktree.

## Delivery sequence

1. File and artifact reading: direct outcome links, Markdown/source, image/PDF,
   CSV, HTML preview, file tabs, find/highlighting, reading positions and bounded
   long-file/tail reads.
2. Project workbench: goals, changes since last visit, source-linked outcomes,
   verification and next action in one project-oriented surface.
3. Companion: watched tasks, current progress, quick reply, full-window handoff,
   menu-bar access and explicit background lifetime.
4. Unified search: session metadata, loaded conversation history, saved outcomes
   and accessible project files; expose the scope actually searched.
5. Delivery tracking: file changes, verification evidence, PR/CI snapshots and
   explicit human acceptance, preserving the differences between those states.
6. Long tasks: persisted one-shot/time/idle follow-ups and inactivity notices,
   clear host/session identity, cancellation and restart handling. Scheduling
   runs while Perch is open; do not imply a remote scheduler is installed.

## Validation

- Core contracts: file formats/limits, search scope, delivery state, job lifecycle.
- Build with scripts/build.sh; WorkbenchChecks and affected host checks.
- Native fixture interactions for new surfaces, keeping build, isolated UI,
  real remote service and user-device evidence distinct.
- No default push, merge or deployment.

## Progress

- [x] Files and artifacts
- [x] Project workbench
- [x] Companion
- [x] Unified search
- [x] Delivery tracking
- [x] Long tasks
- [x] Validation and review

## Acceptance evidence (2026-10-22)

- Release app built with `scripts/build.sh`.
- WorkbenchChecks: passed, including new file/CSV/search/persistence/follow-up contracts.
- ConnectionChecks: passed, including draft-preserving next-turn dispatch, duplicate
  message IDs, offline refusal and history search without selection changes.
- HostLifecycleChecks: all 18 phases passed; the workspace phase was rerun after
  final native changes. It mounts all five new surfaces, exercises the floating
  panel controller, and checks file cancellation, reading restoration, 720/360
  light/dark source views and one-shot inactivity.
- Portable functional suite: all 9 groups passed. The first sandbox run could not
  bind loopback test-server ports; the local-permission rerun passed.
- Localization and the 20 preview/partial-target source manifests passed.
- Full visual screenshot review is incomplete: SwiftUI ImageRenderer and AppKit
  cached-display captures omitted layers; screen-capture preflight was false,
  and computer-use timed out before the temporary fixture could be opened.
  These screenshots are not accepted evidence and are not shipped as previews.
- No real remote-agent, live GitHub PR refresh, deployment or hosted CI acceptance
  is claimed. HTML external resources and app-closed scheduling are not supported.

Usage and limits: [WORKSPACE.md](../WORKSPACE.md).
