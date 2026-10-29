# Workbench home

The workbench answers three questions first: what needs my input, what is running,
and what result can I review? Project directories and task-group planning have
their own views inside the workbench. They no longer push current work below a
long directory listing.

- Sidebar: one Workbench entry, Inbox, All Sessions, existing session shortcuts
  and settings. Remove the duplicate Task Groups destination; keep group data,
  membership actions, editing, goals, outcomes and the group detail page.
- Workbench: a persistent header with New Session and Overview / Projects / Task
  Groups. Overview has three actionable counts, followed by bounded attention,
  running, result and recent-session lists. Historical changes are expandable.
- Projects and Task Groups: reuse the existing project details and group actions.
  Selecting a group opens its scoped workbench. Inbox still contains only actual
  requests for human action; offline sessions never inflate the live counts.
- All Sessions: search still covers the entire unarchived catalog. AppKit owns
  viewport layout and reuses native cells for simple two-line directory rows. Project,
  environment and status are visible, and the session menu retains pin/archive,
  group membership and other actions, including through right-click.
  A catalog reorder preserves the visible session; a query or keyboard selection
  reveals its result. No conversation history is loaded just to render a row.

References checked on 2026-10-29:

- [Linear My Issues](https://linear.app/docs/my-issues): a focused view of relevant
  work, with separate views for different questions.
- [Linear Inbox](https://linear.app/docs/inbox): separate items needing attention
  from general activity.
- [Things lists](https://culturedcode.com/things/support/articles/4001304/): distinguish
  the work to focus on now from its project/area organization.

These are information-architecture references. Perch keeps its native macOS
window, Liquid Glass chrome, current appearance tokens and provider lifecycle.
