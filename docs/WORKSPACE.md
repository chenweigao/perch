# Project workspace and companion

This source preview adds six connected workflows. Existing workspaces retain their
sessions, groups and drafts; the new fields default to empty when loading older files.

## Projects and delivery

The home page's **Project workbench** groups sessions by their sidebar project.
Open a project to save its goal and next step, review requests/results updated since
last seen, open linked outcomes, follow sessions, and record a delivery.

Delivery records keep the source session, full verification commit, evidence notes,
verification result, PR/CI snapshot and human acceptance separately. Refresh uses
`gh pr view` on the project's machine, where `gh` must already be installed and
logged in. GitHub HTTPS PR URLs are supported. The refresh timestamp and HEAD are
shown; acceptance stops applying when the verification commit or PR HEAD changes.
No test, merge, push or deployment is performed by refreshing a record.

## Files and outcomes

File links in saved outcomes open a reader with an explicit source environment.
Project-file search results retain the searched environment even when sidebar
membership differs from a session's execution directory.

- Markdown reading/source modes, syntax coloring for common source extensions,
  and literal find within the loaded source.
- Image and PDF previews up to 16 MiB. Images decode to a bounded display size.
- CSV/TSV tables show up to 200 rows and 40 columns, including quoted multiline
  cells. Switch to source for the loaded text.
- Standalone HTML can run inline interactions. The preview uses an ephemeral
  WebKit store and blocks network, forms, frames and external navigation.
  Reports depending on external scripts, images or adjacent files need a browser.
- Up to 12 recent file tabs per host/project, persisted paths and reading mode,
  plus source and Markdown reading positions. File contents are read again.
- Text reads start at 1 MiB, can expand to 4 MiB, and support a bounded tail view.
  Find and line numbers describe the loaded slice, not the whole large file.

Opening or closing the reader cancels its read; late replies cannot replace a newer
file or another host's content. Source selections can be added to the originating
agent session's draft without sending it.

## Companion and background lifetime

Follow tasks from a project, then use **Workbench → Companion**, the menu-bar bird,
or **Control–Option–P**. The floating panel shows their current state and detail,
opens pending requests in the main window, and queues a short next-turn reply for
the explicitly selected session. Companion drafts are separate from conversation
drafts and persist in the workspace. New-task entry hands off to the main composer.

Enable **Keep running in the menu bar after closing the main window** in Settings
or Follow-ups to keep local scheduling alive. Quitting Perch stops local scheduling;
closing the client never stops its managed remote agent sessions. If another app
owns the shortcut, use the menu bar; Settings reports registration failure.

## Search

**Command–K** opens session metadata, history, saved outcomes and project-file
search. Metadata and outcomes are local. History search explicitly reads online
agent sessions, up to 5000 messages per session and 500 result entries, without
changing the selected session. Opening a result uses conversation find and loads
older history when needed. Offline/archived coverage is not implied; per-session
errors and incomplete coverage are visible.

File search requires `python3` on the project host. It checks up to 1000 files and
25 MiB, at most three matches per file and 200 results. It skips symlinks, common
build directories, non-UTF-8 content and files larger than 1 MiB. Results report
inspected/skipped counts and limits. A new query, scope change, cancellation or
page dismissal prevents the old request from publishing.

## Long-task follow-ups

Follow-ups are persisted one-time rules: send at a specified time, send after the
next new result, or notify after a running task has not updated for a chosen time.
Perch checks every 15 seconds while running. Offline and archived sessions wait;
pending approvals are not bypassed. Time triggers use the existing next-turn queue.
Inactivity is a reminder, not a diagnosis that the remote process has failed.
System reminders follow the app's notification and task-mute settings.

Before queueing a scheduled instruction, Perch durably records its dispatch intent.
The queue uses a stable message ID and is flushed before network delivery. An
interrupted ambiguous dispatch remains **Check send status** after restart and is
not automatically repeated. Inspect the source queue/replies before creating a
replacement rule. Pending rules can be cancelled; queued messages are managed in
the source session's existing queue.
