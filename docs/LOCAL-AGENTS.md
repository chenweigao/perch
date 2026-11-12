# Local agents

Open **Local Agent** on the home screen or in Settings. Perch checks common GUI
installation paths and the inherited PATH with a bounded `--version` probe.
Use **Choose path** for an installation outside those paths. A successful probe
establishes CLI availability, not credentials or successful model inference.

Kimi and Codex can be connected and used in an existing Mac project directory.
OMP, Claude Code, Qoder and dsh are detected but do not yet offer local execution.
The selected executable paths are saved with the stable local environment.

- Kimi and Codex both run through the local native agent bridge (`native-agent-service.py --ensure`),
  with bridge state in `~/.local/share/perch/local-native`. Kimi speaks standard ACP over stdio
  (`kimi acp`), and Codex uses its `app-server` adapter, matching remote sessions without starting
  or managing a `kimi web` HTTP server. The selected executable paths are passed via
  `PERCH_LOCAL_KIMI` and `PERCH_LOCAL_CODEX`.
- Existing conversation, effort, approval, stop and reconnect controls are reused.
  Closing Perch disconnects the client without terminating active tasks.
- File and Git browsing execute the existing read-only commands in the selected
  environment. A local task must use an existing local directory.

## Acceptance on 2026-09-24

Build and offline evidence: `scripts/build.sh`, WorkbenchChecks, ConnectionChecks,
host lifecycle checks, portable checks (including 102 bridge tests and four
metadata tests), and composer toolbar checks for all six agents passed. These
checks do not certify remote model compatibility or performance.

Live checks used an isolated app preference domain and `/tmp/perch-local-acceptance`:

- Kimi 2.0.2: discovered, connected, created a task, returned the requested marker;
  selected Low for aone GPT; a shell read required **Allow once**, then returned
  the fixture content.
- Codex 0.155.0 prerelease: discovered, connected, created a task, returned the
  requested marker. A symlink-specific missing tool-helper failure was fixed and
  covered by a regression test. Shell execution then succeeded.
- During a running Codex shell task, quitting and reopening Perch restored the
  same running task. Stop produced a stopped turn; resuming a queued follow-up
  completed a second shell read and returned `PERCH_LOCAL_FIXTURE`.
- The file panel read the same local fixture; saved sessions survived app restarts.

Other local adapters and fresh-service startup against every CLI version were not
live-tested. Authenticated Kimi reuse was tested live; fresh detached startup and
occupied-port behavior are covered by isolated unit tests.
