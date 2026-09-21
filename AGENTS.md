# Agent Workbench

Independent native macOS client for the public Herdr API and CLI. SwiftUI/AppKit,
GhosttyTerminal, and the system OpenSSH client. Default appearance is light.

- Do not copy code or assets from herdrm (PolyForm Noncommercial).
- Keep credentials in the user's existing SSH configuration and agent.
- Disconnecting a client must not close a remote pane or stop an agent.
- Do not attach with --takeover or enable agent permission bypass implicitly.
- Keep build, UI interaction, remote compatibility, and performance evidence separate.
- Use dedicated branches and worktrees. Do not modify unrelated work.
- Build with scripts/build.sh; run swift run WorkbenchChecks for protocol and command contracts.
