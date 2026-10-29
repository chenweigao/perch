# Workspace, remote sessions and file panels

These boundaries separate state ownership without changing the wire protocol,
workspace/draft formats, notification preferences or remote installation layout.

## Workspace coordination

`WorkbenchModel` owns application lifetime, provider connections, navigation and
workspace mutations. It composes these feature owners:

| Owner | Responsibility |
| --- | --- |
| `WorkbenchNamingState` | Naming attempts per configuration revision, in-flight state, errors and late-result validation |
| `WorkbenchRestorationState` | Reconnect arming and the accumulated session recovery report |
| `WorkbenchNotificationState` | Notification preferences, mute state, event deduplication and toast expiry |
| `AttachedTerminal` | Terminal surface, theme and responder-chain input forwarding |

Existing coordinator properties forward to the feature owners. Observation and
SwiftUI bindings therefore continue to reach the same feature state. Naming reads
the current local/remote title after awaiting the request; a captured workspace
snapshot must never replace a manual rename. Recovery resolves before updating the
dashboard baseline and waits for the native catalog to synchronize. Connections
continue to outlive pages.

## Remote sessions

`Session` owns durable main-conversation state, prompt receipts, process lifetime,
history snapshots and the provider dispatch boundary. It composes:

| Owner | Responsibility |
| --- | --- |
| `CodexSessionAdapter` | App-server connection, frame translation, approvals and child-thread backfills |
| `ACPSessionAdapter` | ACP request correlation, configuration negotiation and pending prompt handoff |
| `SessionSubagents` | Roster indexes, transcript cache, paging, persistence timer and child lifecycle |

Each instance belongs to exactly one session. Collaborators call the session
explicitly to publish messages, advance revisions or persist main state. Existing
lock boundaries and durable JSON fields are unchanged; adapter objects are never
serialized. These classes remain in `native-agent-service.py`, preserving the
single-file installer and source-fingerprint contract. Splitting deployment files
would be a separate packaging change.

## File and Git panels

`RemoteFileBrowser` owns file/document navigation and composes `RemoteGitBrowser`,
which owns repository selection, comparisons, review progress and Git operations.
The browser's forwarding API preserves existing window and inspector callers.

Both owners use one `RemotePanelReadState`: starting a Git read invalidates the
previous file request, and file navigation cancels a pending Git process. The
generation/request identity gates publication even if cancellation returns late.
`RemoteReader` owns one local/SSH process. Git writes own a separate reader and
retain repository-scoped busy state until completion, including across navigation.

`RemoteFilePanel` composes `RemoteGitControls` and `RemoteGitContent` with the same
branch-confirmation and selection bindings. `RemoteSourceText` owns the AppKit text,
gutter and diff rendering. File tabs, review preferences, scroll restoration and
the three independent window/inspector browser instances keep their prior scope.

## Regression checks

- `scripts/build.sh` and the macOS core group: production build/launch, signatures,
  core contracts, connection state and composer behavior.
- `scripts/check-host-lifecycle.py`: coordinator Observation and bindings,
  notification deduplication/muting, file/Git cancellation and write survival,
  reconnect catalog gating, baseline comparison, report dismissal and host/provider
  isolation, file windows, code reading and inspector behavior.
- `scripts/check-naming-lifecycle.py`: loaded-session catch-up, manual rename,
  failed attempt/retry and configuration revision handling.
- `scripts/run-native-acceptance.py`: isolated session switching, workspace,
  inspector and Git review workflows.
- `python3 -m unittest discover -s remote -p 'test_*.py'`: provider frames,
  approvals/stop, receipts, history, child persistence and recovery, including
  interleaved sessions with the same message and child identifiers.
- `windows/tools/generate-fixtures.py`: the existing JSON fixtures must remain
  identical except for the implementation fingerprint after a source edit.

Offline fixtures do not establish live SSH/model compatibility, deployment or
measured performance gains.
