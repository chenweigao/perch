# Perch for Windows (MVP)

A standalone **C# / .NET 8 / WPF** client for viewing and driving existing **Perch native
Agent sessions** on a remote Linux dev machine, from Windows 10/11 x64.

This is an independent client added under `windows/`. It does **not** port the macOS
SwiftUI UI, does **not** modify any Swift or `remote/` source, and copies nothing from
herdrm. It talks to the same remote bridge as the macOS client —
`remote/native-agent-service.py` (bridge protocol **v9**) — over an SSH loopback forward.

> **Scope of this MVP.** Connect to an already-running bridge, list sessions, open a
> session, load and incrementally stream its messages, send a message, and cancel the
> current turn. It supports the existing `codex` sessions the bridge already serves. It
> does **not** install or start the remote service, create sessions, or answer approval
> prompts — pending approvals are **displayed as status only** and never auto-approved.

---

## What was actually verified, and what was not

This MVP was developed and checked on a **Linux** host with .NET 8 SDK and PowerShell 7.
There is **no Windows GUI, no real `ssh.exe`, and no remote bridge** on that host.

**Actually run and passing (this host, Linux):**

- `windows/scripts/Test.ps1` — **127 core tests pass** (`dotnet test`). The core library
  has no WPF/Windows dependency, so the protocol, SSH-argument, transcript-merge,
  session-state, and secret-handling tests run natively on Linux.
- `windows/scripts/Build.ps1` — the whole solution builds clean (0 warnings, `TreatWarningsAsErrors`
  on the core), including the **WPF app cross-built for `net8.0-windows`** via
  `EnableWindowsTargeting`.
- `windows/scripts/Publish.ps1` — publishes `Perch.exe` for **win-x64** from Linux.
- `windows/tools/generate-fixtures.py` — regenerates every fixture from the **real**
  bridge code (imports `remote/native-agent-service.py`, replaces only the Codex
  app-server with an in-process fake). The tests decode that real JSON.
- Exit-code propagation: a failing native command makes the script exit with that
  command's own code (verified: native `42` → script `42`; a broken build → `1`).
- Chinese + space working path: build and test both run when the repo is copied to
  `…/中文 路径 test/`.

**NOT verified — requires a real Windows machine (see “Windows acceptance” below):**

- Launching the WPF window and any on-screen layout/interaction.
- A real end-to-end `ssh.exe` loopback forward to a live remote bridge.
- The Windows ACL audit of a token file (`WindowsTokenFilePermissionChecker`) against a
  real NTFS DACL.
- Real OpenSSH discovery under `%ProgramFiles%\OpenSSH\ssh.exe` and the system SSH agent.
- Actual streaming of a live model turn, and a real cancel/abort round trip.

The CI workflow (`.github/workflows/windows-client.yml`) runs on `ubuntu-24.04`: it runs
the core tests, cross-builds and publishes for win-x64. **It is not a Windows run and
cannot start the GUI or perform a real SSH round trip.** It has not been triggered.

---

## Layout

```
windows/
  Perch.Windows.sln
  global.json                      # pins the SDK band (.NET 8)
  src/Perch.Core/                  # portable: protocol, SSH argv, transport, state, secrets
    Protocol/Models.cs             #   wire records for bridge v9 + JSON options
    Bridge/BridgeClient.cs         #   route builders + typed calls
    Ssh/SshCommand.cs              #   argv builder, POSIX quoting, ssh locator
    Ssh/SshTunnel.cs               #   loopback-forward lifecycle (kill = local only)
    Transport/BridgeTransport.cs   #   HTTP bearer transport + fake for tests
    State/Transcript.cs            #   index-based delta merge (no duplicate appends)
    State/SessionController.cs     #   connection + selection generation guards
    State/MessageProjection.cs     #   wire parts -> display blocks
    State/Outbox.cs                #   send-state tracking
    Secrets/BridgeToken.cs         #   in-memory token, secure input + file providers
    ConnectionCoordinator.cs       #   handshake -> health gate -> poll loop
  src/Perch.App/                   # WPF UI (thin; binds to the controller)
  tests/Perch.Core.Tests/          # xunit; runs on Linux
    fixtures/*.json                # real bridge output (regenerate, don't hand-edit)
  tools/generate-fixtures.py       # derives fixtures from remote/native-agent-service.py
  scripts/{Common,Build,Test,Publish}.ps1
```

`Perch.Core` is deliberately WPF-free and Windows-API-free except behind interfaces
(`ISshProcessLauncher`, `ITokenFilePermissionChecker`, `ILocalPortAllocator`), so all
core logic is testable headless on Linux. `Perch.App` holds only XAML + a view model that
marshals controller callbacks onto the WPF dispatcher.

---

## Protocol mapping (bridge v9 → client)

Every route below is what `remote/native-agent-service.py` actually serves; the response
shapes are the ones in `windows/tests/.../fixtures/`, generated from that file.

| Client action | HTTP | Notes |
|---|---|---|
| Verify connection | `GET /health` | `version` must equal `SERVICE_VERSION` (9). Older → “update the bridge”; newer → “update Perch”. Also reads `implementation`/`startedAt`. |
| List sessions | `GET /sessions` | `SessionSummary[]`; sorted newest-`updated` first for the sidebar. |
| Open a session | `GET /sessions/{id}?turns=25` | First paged read establishes `history.epoch/start/total`. |
| Poll for updates | `GET /sessions/{id}?revision={r}&start={s}&epoch={e}` | Streaming is **revision polling with deltas**, not SSE/WebSocket. Returns `{"unchanged":true}` when `revision` matches, else a snapshot whose `history.indices` name the changed message positions. |
| Send (idle) | `POST /sessions/{id}/prompt` `{requestId,text}` | `requestId` makes a resend idempotent; the bridge echoes the user message under that id. |
| Send (busy) | `POST /sessions/{id}/steer` `{requestId,text}` | Codex running guidance; only when the snapshot says the turn is live. |
| Cancel turn | `POST /sessions/{id}/abort` `{turnId}` | `turnId` must match the live turn or the bridge answers “轮次已变化”. **Distinct from disconnect.** |

That is the whole surface the MVP uses. The bridge also serves `/models`, `/setup`,
`/sessions/{id}/requests/{id}` and older-page reads (`?before=`); this client deliberately
does not call them, so it carries no route builders or decoders for them.

**Auth.** `Authorization: Bearer <token>` on every request. The bridge compares it in
constant time (`hmac.compare_digest`) and answers **401** otherwise. The client treats 401
as “credential invalid, reconnect” and does not retry.

**Streaming model.** The bridge does not push. It replaces whole message positions and
bumps `revision`. A growing reply arrives as the *full* text at one index each tick; the
delta names only changed indices. `State/Transcript.cs` merges by index — so repeated
polls replace the streaming reply in place instead of re-appending it. The
`epoch` / `baseRevision` / `start` guards force a clean full re-read when history was
replaced, a tick was missed, or the window moved, instead of corrupting the transcript.

**Approvals.** `snapshot.interactions[]` carries pending approvals/questions (e.g.
`name: "shell"`, `input.command`). The MVP renders them as a read-only banner. It never
calls `POST /sessions/{id}/answer`, so nothing is auto-approved or auto-denied.

---

## Security rules this client enforces

- **SSH argv is structured, never a shell string.** `SshCommand.TunnelArguments` returns
  an argv array; `SshTunnel` starts `ssh.exe` with `ProcessStartInfo.ArgumentList` and
  `UseShellExecute=false`. Message text travels as **JSON in the HTTP body**, never
  interpolated into any shell.
- **Host keys strictly checked.** `StrictHostKeyChecking=yes`, `BatchMode=yes`,
  `ExitOnForwardFailure=yes`. Unknown or changed host keys fail the connect; Perch never
  auto-accepts and never stores a password.
- **Loopback only.** The forward spec is `127.0.0.1:{local}:127.0.0.1:{remote}` on both
  ends, so the bridge is never exposed to the LAN.
- **No takeover.** No `-tt`, no `ControlMaster`, no remote command. This client attaches
  to sessions; it does not seize or terminate remote panes or agents.
- **Disconnect = local only.** `SshTunnel.KillTunnel()` kills just the local `ssh.exe`
  forward and `ConnectionCoordinator.DisconnectAsync()` stops polling and closes the
  transport. The remote bridge and any running turn keep going.
- **Token handling.** The token comes from a WPF `PasswordBox` (`SecureString`) or from a
  file the user points at. `BridgeToken.ToString()` is redacted; the value is held in
  memory only and never written to disk or logs. A token file whose ACL lets other local
  users read it is **refused before being opened**.

---

## Run it (Windows 10/11 x64)

Prerequisites: **.NET 8 Desktop Runtime** (for the framework-dependent build) and the
Windows **OpenSSH client** (`ssh.exe`, normally `%SystemRoot%\System32\OpenSSH\`). Your
existing `~/.ssh/config`, keys and SSH agent are used as-is — the SSH alias you type must
already be configured to log in non-interactively (BatchMode cannot prompt).

Build and publish from PowerShell 7 (works on Windows, or cross-builds on Linux/macOS):

```powershell
cd windows
./scripts/Build.ps1                 # build core + WPF app
./scripts/Test.ps1                  # core tests (also runs on Linux)
./scripts/Publish.ps1               # -> windows/dist/win-x64/Perch.exe
./scripts/Publish.ps1 -SelfContained  # bundle the runtime (no .NET install needed)
```

Then run `dist\win-x64\Perch.exe`. In the connect panel enter:

1. your **SSH alias** (or `user@host`) — ports/identity/jump hosts live in `~/.ssh/config`;
2. the **remote bridge loopback port** (from the host's `…/agent-workbench/native/endpoint.json`,
   which the macOS client or `--ensure` produces — this client does not start it);
3. the **token**, either pasted into the secure field or loaded from a restricted file.

The bridge must already be running on the remote host.

### Regenerate fixtures after a bridge change

```bash
python3 windows/tools/generate-fixtures.py
```

This re-derives `windows/tests/Perch.Core.Tests/fixtures/*.json` from the real bridge.
CI fails if the committed fixtures drift from the current bridge output.

---

## Windows acceptance (manual — not run here)

On a real Windows 10/11 x64 machine with a reachable Linux dev host that has a running
bridge:

1. **Connect.** Enter the SSH alias, remote port, and token. Confirm the sidebar lists the
   host's sessions. Check the SSH child binds only `127.0.0.1` (e.g. `netstat -ano`).
2. **Host key.** Point at a host with an unknown key: the connect must **fail** with the
   host-key hint, and no `known_hosts` entry may be added automatically.
3. **Open + stream.** Select a busy `codex` session. Watch a live reply grow in place —
   it must not duplicate or re-append text across polls.
4. **Switch sessions.** While a reply streams, switch to another session and back. The old
   session's content must never appear under the new selection.
5. **Send.** Send a message containing Chinese, emoji, spaces, quotes and shell
   metacharacters (e.g. `中文 🚀 C:\路径 空格 "引号" && \`whoami\``). Confirm it is delivered
   verbatim and the user bubble shows it unchanged.
6. **Cancel vs disconnect.** With a turn running, click **取消回合** — the turn stops but
   the connection stays. Then click **断开** — the local `ssh.exe` exits, the UI goes
   offline, but the remote bridge/agent is untouched (verify on the host).
7. **Approval.** Trigger a command that needs approval. The banner must show it as pending;
   Perch must **not** approve or deny it.
8. **Failure paths.** Kill the SSH connection (drop VPN): the UI reports a fault and offers
   reconnect without crashing or leaking the token.
9. **Token file ACL.** Point at a token file readable by `Users`: it must be refused. Point
   at one readable only by you: it loads.

---

## Known gaps / limitations

- **No answer flow for approvals** (by design for this MVP) — view-only.
- **No session creation, model switch, archive, delete, subagents, or attachments** — the
  bridge supports them, this MVP intentionally does not surface them.
- **Only the latest history page is loaded.** The bridge supports older-page reads
  (`?before=`), but this MVP shows the most recent `turns=25` window of the selected
  session and does not scroll further back. The delta-merge guards still hold if a full
  re-read is ever forced.
- `codex` sessions only; other providers are listed if the bridge returns them but the
  send path assumes Codex steering semantics (steer is gated on the session's declared
  `steer` capability, else it falls back to `prompt`).
- Local port allocation binds-then-releases an ephemeral port; a narrow race with another
  process grabbing it before `ssh` rebinds is possible (same approach as the macOS client).
- The WPF UI has never been rendered or clicked on Windows in this environment.
