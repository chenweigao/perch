# Project workspace and companion

This source preview adds six connected workflows. Existing workspaces retain their
sessions, groups and drafts; the new fields default to empty when loading older files.

## Projects and delivery

The home page's **Project workbench** groups sessions by their sidebar project.
Open a project to handle requests, review new results since last seen, and see running
tasks in that order. Marking results seen does not hide pending requests. Project details
hold the editable goal, next step and environment; the full session list is collapsed.
Linked outcomes, followed sessions and delivery records remain available.

Delivery records keep the source session, full verification commit, evidence notes,
verification result, PR/CI snapshot and human acceptance separately. Refresh uses
`gh pr view` on the project's machine, where `gh` must already be installed and
logged in. GitHub HTTPS PR URLs are supported. The refresh timestamp and HEAD are
shown; acceptance stops applying when the verification commit or PR HEAD changes.
No test, merge, push or deployment is performed by refreshing a record.

## Files and outcomes

Conversation links, search results and saved outcomes reuse the same native reader
window and its tabs. A saved outcome keeps its source environment, including when
linked from another project. When the origin is missing, the reader asks for it.
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
agent session's draft without sending it. Each tab persists its source session; switching
the main conversation does not change the file or its quote destination. The action
menu names that destination. Closing a tab during a read also rejects its late response.

The reader opens in a separate, resizable macOS window and remembers its window
frame. Recent files use tabs above a compact toolbar. Open-path controls, source
environment and file details are available on demand; find expands only when used.
The actions menu contains refresh, line numbers, larger reads and quote/feedback
commands. Use Command–L for a path, Command–Shift–L for a loaded line,
Command–Shift–[ / ] to switch tabs, and Command–W to close the current tab (or the
window for the last tab). Closing the reader cancels its file read and retains saved tabs.

Files and conversation code blocks share language-aware highlighting from bundled
highlight.js. The reader displays source first, then fills colors in the background;
large loaded slices retain highlighting. TextKit lays out requested ranges instead
of blocking on the entire document. Find searches the loaded slice asynchronously,
keeps all matches, and reuses those positions for next/previous navigation.
Unknown languages stay plain text, and selection/copying always use original text.
Large files use a separate background parser so their coloring cannot queue small
code blocks behind them. Bounded token caches make repeated reading cheaper; see
[the matched measurement](performance/2026-10-23-highlighting/REPORT.md).

## Document reading

Markdown opens in the native reader with an on-demand heading outline, four font
sizes and three reading widths. Command–F keeps Markdown rendered: it highlights
literal text and moves through matching paragraphs. The count refers to matching
paragraphs, not individual occurrences. Search covers the loaded portion only.

Relative document links and heading anchors resolve on the document's own host.
Reference-style Markdown links keep their targets. Command–[ / ] and the toolbar
arrows move through file history; saved tab positions restore when returning.
History resets when changing host/project. The existing twelve-tab limit applies.

Referenced local/remote image files load from that same environment with bounded
reads and downsampled display. External image URLs are explicit browser links;
the reader does not silently fetch web images. Markdown HTML remains literal text.

Select rendered text and use **Give feedback on selected text** in its context menu.
The sheet keeps the excerpt, document path, chapter and original conversation.
Adding feedback (Command–Return) updates that conversation's draft without sending it. Switching
the main conversation never retargets an open document's feedback.

A project's **Documents** section holds pinned documents and collapsible recent
reading. Pin from the file actions menu or a document row; unpin/remove only affects
the list. Markdown, PDF, HTML, tables and images can be collected. Entries retain
host, path, source conversation, last-read time and the file modification time last
observed when reading. This is not a background file watcher. Pinned entries are
preserved; unpinned recent entries are bounded to 100 across the workspace.

## Companion and background lifetime

Follow tasks from a project, then use **Workbench → Companion**, the menu-bar bird,
or **Control–Option–P**. The floating panel puts requests first, then unread results,
running work and other followed tasks. Only requests and the selected task expand detail. It
opens pending requests in the main window, and queues a short next-turn reply for
the explicitly selected session. Companion drafts are separate from conversation
drafts and persist in the workspace. New-task entry hands off to the main composer.

Enable **Keep running in the menu bar after closing the main window** in Settings
or Follow-ups to keep local scheduling alive. Quitting Perch stops local scheduling;
closing the client never stops its managed remote agent sessions. If another app
owns the shortcut, use the menu bar; Settings reports registration failure.

## Task context panel

The conversation header's **Task panel** toggles a card inside the conversation page containing
pending requests, documents, background tasks/subagents, and current-turn tool
activity. Empty sections stay hidden; completed calls start collapsed. The panel
uses a 280–340 point trailing card when the page can also fit the full 680 point
reading column and its margins (at least 1,056 points of page width). The transcript
and composer shift together and recenter when the card closes. Smaller windows
show a compact entry above the conversation that opens the independent floating
panel; it neither covers the transcript nor reads task data while collapsed to
that entry. Widening the page restores the card.
The card fits its header and visible sections, up to 620 points or the available
page height. Expanding a section grows the card until that limit, then scrolls its
contents. Its compact header keeps task controls visible; the independent window
also offers conversation and draft actions in its footer.
It stays open while interacting with the conversation and can be collapsed with
its close control or the header button. Resizing and toggling retain the same
conversation view, reading position, and composer. The card can detach into a
resizable native window, then return with **Show in conversation**. Only one
presentation reads at a time. Navigating away from the conversation removes the
embedded card and ends its reads. **Lock to this task** preserves the
source host and session while the main window navigates; unlocking resumes
following the current conversation. Closing it ends its reads, not remote work.

Native agents reuse the current snapshot when available and independently read
up to 20 turns for another session. Kimi reads the snapshot and task list through
its existing connection. Projection is bounded to the last 160 available messages;
document links scan at most 131,072 characters and retain up to 40 unique files.
This is a recent-context view, not an exhaustive project inventory. Visible panels
refresh every 2 seconds during activity or 8 seconds while idle. A failed read
shows an unsynchronized state and offers retry.

Document rows collect explicit Markdown links/images, inline file references, and
successful write/edit calls for supported document extensions. Only confirmed
write/edit results receive **Updated this turn**; other paths are **Related file**,
whose existence is checked when the normal file reader opens them on the original
host. Reading a file never selects another conversation.

Pending requests open the existing review UI. Kimi background tasks can show an
on-demand output tail (up to 16 KiB) and request cancellation. Native subagents
offer Stop only when the runtime marks them individually stoppable; a fresh roster
is checked before issuing it. Stop acknowledgement does not mark a task finished;
the subsequent task state does. Unconfirmed stops become retryable after 15 seconds.
Subagent details continue to use the full conversation.

The independent window’s **Add instructions** captures the source task when opened and appends to that task's
existing draft. It does not send a message. The task panel and the older followed-task
companion remain separate views: one follows a conversation, the other lists tasks
explicitly followed from the workbench.

## Search

**Command–K** opens session metadata, history, saved outcomes and project-file
search. The input starts focused; Up/Down selects available results, Return opens
the selection and Escape closes the sheet. For history/files, the first Return starts
search; changing the query cancels that request and clears obsolete results. Search
coverage details are expandable. Metadata and outcomes are local. History search explicitly reads online
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
