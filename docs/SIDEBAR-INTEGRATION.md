# Floating sidebar integration

This integration brings Goal A (`352b66c`), Goal B correctness fixes
(`1399902`), and tool visibility (`c7e3192`) onto one local baseline.

## Sidebar behavior

- Keep the existing AppKit sidebar split item: system floating glass, width
  restoration, and a draggable 220–420 pt divider.
- Fixed top: Perch, new task (⌘N), task search (⌘K), workbench, attention inbox.
- Scrollable middle: pins, task groups, up to 20 recent sessions, all sessions.
- Fixed bottom: archive, environment popover, native Settings entry (⌘,).
- Workbench/group/archive selection changes the main page, not the sidebar's
  daily session scope. Recent filters (all/running/local) affect recents only.
- Attention counts only online sessions needing intervention. Unread results
  remain in the workbench review section.
- Pins, task groups and recent-session headings align with the row icons' left
  edge. Group creation and the recent filter use matching 24 pt action areas.
- Native conversation blue dots mean an unseen completed result. Kimi, OMP and
  Qoder acknowledge the result loaded into the visible, active conversation when
  following the latest content. A cached Kimi transcript awaiting refresh, an
  inactive app, an older scroll position or a pending/error state does not count
  as a read. The stored cursor comes from the displayed snapshot, not a newer
  catalog entry. Explicit workbench review controls remain available.
- Search uses a sheet and its own query. All sessions uses the main area. Both
  search active sessions; archived sessions have their separate page.
- Environment controls operate on their own connections without changing the
  selected conversation, host scope, or task group.
- Settings reuses the existing local Agent and SSH configuration dialogs.

## Integration constraints

The native conversation viewport from A remains in place. Tool visibility feeds
its stable row projection; Kimi retains its timeline across selection changes.
No remote protocol deployment, real session operations, app replacement, or
publication is part of this change.

Goal A performance acceptance remains partial and paused. See
`PERFORMANCE-VIEWPORT-PROBE.md`; this sidebar integration does not establish a
3× end-to-end improvement or a new long-run result.

## Validation

`scripts/build.sh` packages a local release app. `WorkbenchChecks` covers
protocols, task controls, file operations, tool visibility, and sidebar scoping.
`scripts/build-sidebar-preview.sh` builds a separate app using the production
sidebar shell and native split view with fictional rows; it never loads the
workspace model or connects to agents. This fixture checks presentation and
shell interactions, not live-provider behavior.

For automatic read-state acceptance on macOS: open an unread completed conversation
and confirm its dot clears after loading. Switch away, complete another turn and
confirm its dot returns. Repeat with a failed load, with the app inactive, and
while scrolled to older content; those must not acknowledge the latest result.
Confirm approvals/errors remain actionable and read state survives an app restart.

### Checked on 2026-09-21

- Release app compiled, packaged and ad-hoc signed successfully.
- WorkbenchChecks exited 0, including the added sidebar projection checks.
  Live SSH checks were intentionally skipped.
- Sidebar fixture: inbox/archive selection, middle-only scrolling, retained list
  position, anchored environment popover, ⌘K search sheet, native Settings window,
  and divider drag from 278 to 355 pt verified via UI.
- Tool fixture: live-to-history deduplication and expanded state, completed tool
  output including its final line, and a separately visible overview verified.
- Both fixture apps were closed after the checks. The normal Perch app was not
  launched or replaced.

## Compact session rows

Ordinary sessions use a 34 pt, single-title-line row. Only attention and offline
states add an explanation line (48 pt row). Leading status icons identify running,
actionable, unread, disconnected and ordinary sessions; hover help retains the
full title, Agent, host, directory and status.

Pin and archive appear on hover, selection or keyboard focus. Restore remains
visible in archived rows. Actions reserve 48 pt on the right, so revealing them does not
reflow or truncate the title differently. Running sessions have no quick archive
action. Archived rows expose restore instead of pin/archive. Other actions are
available in the row context menu; destructive actions retain the existing
provider-specific confirmation. There is no separate ellipsis button per row.

Rename stores a local Perch display name keyed by the complete session reference.
It applies to the catalog, header and saved open-view titles and survives reload;
it does not rename a session in the remote provider. Older workspaces load with
no overrides, and deleting a session removes its override.

Compact-row validation (2026-09-21): release build and WorkbenchChecks passed,
including local-title round-trip, legacy workspace decoding, cross-host identity
and deletion cleanup. The shared row component was checked in the isolated
sidebar fixture at 355 and 270 pt sidebar widths: selected-row actions, pin/unpin,
no quick archive for running rows, archive/restore, and the right-click menu.
The fixture uses in-memory actions; no real sessions were changed. The preview
was closed after verification. Hover-only reveal and live-provider operations
were not separately exercised by the automated UI checks.
