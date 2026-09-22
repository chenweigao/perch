# Remote agent setup

The entry point is **Environment → +**, the first-run home action, or `⌘N` with
no saved machines. Existing machines use the same flow from their gear button or
Settings. The three steps are Connect machine, Prepare agent, and Start task.

The design follows the task order: connection identity first, selected runtime
next, then the project and first prompt. SSH aliases are discoverable, technical
settings are disclosed only when relevant, and errors appear beside repair
controls. This takes inspiration from [Codex's SSH connection workflow](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host), while using Perch's existing adapters.

## Contracts

- A fresh workspace has no preset host and starts no SSH processes. Old saved
  endpoint IDs and their session/draft associations are retained. An old implicit
  `dev-env` with a saved open session is restored as an existing environment.
- New hosts enable only the chosen agent. Kimi setup does not require Herdr or the
  native bridge. OMP installation does not require the Qoder SDK or npm.
- Kimi routing settings contain only a port and a remote token-file path. The
  token is still read over SSH and retained only in memory.
- Setup connections do not load drafts or outboxes. A probe cannot drain an
  existing user's queued messages or replace their selected conversation.
- Checking a service does not invoke model inference. Qoder authentication and
  dsh's model handshake are explicitly reported as first-message/session checks.
- Failed/cancelled checks cannot save a host or open a task. Remote installation
  and service startup are explicit buttons; cancellation does not undo them.
- The same machine UUID, agent, checked project path and selected model are
  passed to the existing task composer. No duplicate task-creation path is added.
- Removing a machine only disconnects the Mac and removes the local entry. The
  final machine can be removed. Remote tasks and task-group references remain.

## Validation

Portable checks:

```sh
python3 -m unittest discover -s remote -p 'test_native_service.py'
python3 -m unittest discover -s Tests/RemoteSetup -p 'test*.py'
python3 -m unittest discover -s Tests/Localization -p 'test*.py'
python3 -m unittest discover -s Tests/Publication -p 'test*.py'
python3 scripts/check-localization.py
python3 scripts/check-public-source.py
bash -n scripts/build.sh scripts/install-native-service.sh
```

Required on macOS:

```sh
./scripts/build.sh
swift run WorkbenchChecks
python3 scripts/check-host-lifecycle.py
```

WorkbenchChecks covers endpoint migration, shell quoting, SSH validation,
whitespace in remote directory names, check cancellation and timeouts. The host
lifecycle executable uses isolated preferences and checks empty first run, setup
handoff, endpoint/draft persistence, probe isolation and last-host removal.

Manual interaction checks on macOS: start with isolated preferences; connect a
Kimi-only server without Herdr; repair an untrusted SSH key and a missing Kimi
service; choose a custom Kimi port/token path; browse a directory containing
spaces; begin a task and confirm its machine/model/directory. Check OMP without
Node/npm and Qoder without OMP. Cancel a check and retry on a different host;
reopen Settings; remove the last host. Verify English and Chinese layouts and
Terminal automation permission handling.

Linux validation does not establish macOS compilation, SwiftUI layout, Terminal
Apple events or a complete first-task SSH round trip. Those remain separate
acceptance checks.

On 2026-09-22, the Linux checks passed: 49 bridge tests, 4 installer tests,
4 localization tests and 17 publication tests. The live OMP 18.1.16 setup probe
read 15 configured models after normalizing its `{ "models": [...] }` response;
it did not send a prompt. Its first sandboxed attempt failed with a read-only
CLI database, and the original check was replayed with normal user permissions.
The macOS build and WorkbenchChecks could not run on that host (`swift` absent).
