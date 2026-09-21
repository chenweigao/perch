# Contributing

Perch is built with SwiftUI/AppKit, a shared `WorkbenchCore`, and remote agent
adapters. Keep changes focused and describe the problem, resulting behavior and
validation. For larger changes, discuss the scope in an issue first.

## Development

Follow [the setup guide](docs/GETTING-STARTED.md) and `AGENTS.md`. Use a dedicated
branch and worktree. Run `scripts/build.sh`, `.build/release/WorkbenchChecks` and
`git diff --check`; add tests for the behavior you change. Remote bridge tests run
with `python3 -m unittest discover -s remote -p 'test_*.py'`.

Use the independent fixtures under `Tests/ReadingPreview`, `Tests/ComposerPreview`
`Tests/SidebarPreview`, `Tests/ReplyTypographyPreview` and `Tests/PerformancePreview` for UI work. A successful build is not a visual or
performance check. Report the workload and measurement scope with performance claims.

## Agent adapters

Reuse conversation, tool and approval components. Keep protocols separate from UI.
Document supported runtime versions, cancellation and permission behavior, and test
history reading, resuming a stopped session and attaching to a running session as
separate capabilities. Do not implicitly take over or stop users' existing sessions.

Never commit keys, tokens, real conversation exports or internal screenshots. Use
synthetic fixtures and `example.com` hosts. Before sharing a source snapshot, run
`python3 scripts/check-public-source.py`; its pattern checks supplement manual review.

Third-party code and assets need attribution and compatible licensing. See
[THIRD_PARTY.md](THIRD_PARTY.md).

For the one-time public migration and subsequent releases, see
[RELEASING.md](docs/RELEASING.md).
