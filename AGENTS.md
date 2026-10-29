# Agent Workbench

Independent native macOS client for the public Herdr API and CLI. SwiftUI/AppKit,
GhosttyTerminal, and the system OpenSSH client. Appearance follows the system;
Settings offers light/dark overrides. Acceptance and preview fixtures stay pinned
to light.

- Do not copy code or assets from herdrm (PolyForm Noncommercial).
- The window is one system Liquid Glass backdrop (`WorkbenchWindowBackdropView`,
  `.regular` glass over a non-opaque window, shaped like the window corner), shared
  by navigation and the toolbar. In light its tint comes from the desktop alone;
  in dark it floats on `WorkbenchTheme.glassUnderlay`, a mostly opaque
  blue-graphite base (user direction of 2026-10-29), so night chrome shares the
  canvas's luminance instead of the wallpaper's. Fills, strokes and elevation are
  independent light/dark tokens (`WorkbenchTheme.Fill` / `Stroke` / `Elevation`),
  never one alpha shared by both appearances. The sidebar has no separate glass
  card, outline, or shadow in the wide layout; its selection is a light row card.
- The opaque workspace sheet floats below the toolbar. The full-height inspector
  is an internal auxiliary lane separated by a hairline, without its own rounded
  card or shadow; opening it resizes the reader and composer together. Keep the
  outer sheet concentric with the window corner (`WorkbenchTheme.Radius.framePanel`)
  and its elevation light. Sidebar width remains user-adjustable and persisted;
  navigation uses compact, secondary controls. Preserve native Liquid Glass on the
  composer and controls. This follows the user's integrated-inspector direction
  of 2026-10-28.
- Keep credentials in the user's existing SSH configuration and agent.
- Disconnecting a client must not close a remote pane or stop an agent.
- Do not attach with --takeover or enable agent permission bypass implicitly.
- Keep build, UI interaction, remote compatibility, and performance evidence separate.
- Never develop in this primary checkout. For each task create a worktree at
  `../_worktrees/<task>/perch` on a dedicated branch (`feat/<task>`, `fix/<task>`,
  or `codex/<task>`) and make all commits there. This directory only tracks
  `main` and reviews others' work. Do not modify unrelated work.
- Build with scripts/build.sh; run swift run WorkbenchChecks for protocol and command contracts.

- New or migrated UI features follow `docs/architecture/state-and-effects.md`:
  Observation state owners, explicit dependencies, and `.task(id:)` for page-bound
  work. Keep remote connection lifetimes independent of page navigation.
