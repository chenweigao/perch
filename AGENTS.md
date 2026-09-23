# Agent Workbench

Independent native macOS client for the public Herdr API and CLI. SwiftUI/AppKit,
GhosttyTerminal, and the system OpenSSH client. Default appearance is light.

- Do not copy code or assets from herdrm (PolyForm Noncommercial).
- Preserve the existing native Liquid Glass appearance, including its adaptive
  background tint, on the sidebar and composer. UI simplification should change
  inner controls and layout only; do not replace the outer glass material with
  fixed fills, custom borders, or another surface style.
- Keep credentials in the user's existing SSH configuration and agent.
- Disconnecting a client must not close a remote pane or stop an agent.
- Do not attach with --takeover or enable agent permission bypass implicitly.
- Keep build, UI interaction, remote compatibility, and performance evidence separate.
- Never develop in this primary checkout. For each task create a worktree at
  `../_worktrees/<task>/perch` on a dedicated branch (`feat/<task>`, `fix/<task>`,
  or `codex/<task>`) and make all commits there. This directory only tracks
  `main` and reviews others' work. Do not modify unrelated work.
- Build with scripts/build.sh; run swift run WorkbenchChecks for protocol and command contracts.
