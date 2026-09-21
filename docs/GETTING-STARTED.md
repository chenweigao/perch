# Getting started

## Local build

Use a Swift toolchain with the macOS 26 SDK. Perch targets macOS 14+, with Liquid
Glass enabled only on macOS 26. Dependencies are pinned in `Package.resolved`.
The build downloads dependencies, compiles Release, packages resources and signs
`build/Perch.app` locally. It does not install remote software.

```sh
./scripts/build.sh
open build/Perch.app
.build/release/WorkbenchChecks
```

If the build fails with `PackageDescription` / `swiftLanguageModes` linking errors,
the existing workaround creates local toolchain copies without changing the system:

```sh
./scripts/prepare-local-swiftpm.sh
SWIFTPM_CUSTOM_LIBS_DIR="$PWD/.local/swiftpm-libs" ./scripts/build.sh
```

## SSH and agents

Configure your host in `~/.ssh/config`, then confirm authentication and its host
key in a terminal. Perch uses your system SSH configuration and agent; it does not
save SSH passwords or disable host-key checks.

```sshconfig
Host dev-env
    HostName server.example.com
    User developer
```

`dev-env` is the current fresh-install default, not a bundled server. Add other SSH
hosts using **Environment → +** at the bottom of the sidebar (or Settings → Add SSH environment). Kimi currently selects `dev-env` when present,
otherwise the first saved host, with remote port `58627`; there is no multi-service
Kimi configuration UI yet.

- **Kimi:** [run Kimi Web on the remote host](KIMI.md). Perch forwards its loopback
  port and reads its service token through SSH.
- **OMP / Qoder CN:** [install the remote bridge](NATIVE-AGENTS.md) after configuring
  the corresponding CLI and credentials on the server. The installer downloads the
  official SDK; the Mac app does not bundle agent runtimes.
- **CLI terminals:** install and run Herdr on the host. The tested version is 0.9.0;
  its SSH server must allow Unix socket forwarding. Herdr is not required locally.

## Daily use

Use `⌘N` to create a native conversation and select an agent and remote directory.
Use task groups for related work and the sidebar for navigation. Hover a session
for pin and archive actions; right-click for a local display name, grouping and
deletion. Active work cannot be quick-archived. `⌘T` opens a remote terminal.

Native OMP / Qoder CN offer Stop and queued next-turn messages, not live steering.
Local Agent setup currently discovers OMP and checks its version; local native
execution is not available yet. Remote file viewing and read-only Git diff are
experimental. Configure models and credentials in each agent's CLI.

Closing a local view disconnects the client. Ending a remote terminal or deleting
history is a separate explicit action. Perch does not take over another attached
Herdr client or enable permission bypass automatically.

Workspace layout is saved locally. Drafts and pending attachments currently live
only for the current App process. Remote session survival depends on its runtime;
see the adapter documentation for disconnect, restart and history boundaries.
