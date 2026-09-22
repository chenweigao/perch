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

## Connect your first remote agent

Choose **Connect a remote machine** on the home screen, **Environment → +**, or
**Settings → Add SSH environment**. `⌘N` also opens setup when no machines exist.
Fresh installations have no preset host.

1. **Connect machine.** Enter an SSH alias or `user@host`, or choose a concrete
   alias from `~/.ssh/config`. Perch verifies non-interactive SSH authentication.
   If a fingerprint or login needs attention, the error explains the next step
   and opens Terminal on that host. Ports, jump hosts and keys remain in your
   system SSH configuration. Perch does not store SSH passwords or bypass host-key checks.
2. **Prepare agent.** Choose Kimi, OMP, Qoder CN, DeepSeek or Herdr terminals, then
   click **Check agent**. Each check displays its result and repair actions.
   CLI installation and login open in Terminal; the displayed install commands
   use the documented tested versions. Agent credentials stay on the server.
3. **Start task.** Browse the remote folders or enter an absolute project path.
   Perch checks that the directory exists and is accessible. Select a configured
   Kimi/OMP model, or keep the native agent's default. Continue into the task
   composer with the machine, agent, directory and model already selected.
   You can also save the setup and start later.

For example, your SSH config can contain:

```sshconfig
Host my-server
    HostName server.example.com
    User developer
```

### Agent preparation

| Agent | Setup actions | What the check establishes |
| --- | --- | --- |
| Kimi | Install CLI, sign in/configure models, start Kimi Web | CLI version, service authentication and protocol, configured models |
| OMP | Install CLI, configure models, install bridge | CLI version, bridge health, fresh model catalog |
| Qoder CN | Install CLI, sign in, install bridge and SDK | CLI version, Node and SDK presence, bridge health; login is verified on the first message |
| DeepSeek | Install bridge with bundled dsh runtime; configure remote `DEEPSEEK_API_KEY` | Runtime version and credential presence in the bridge environment; models are read during the first ACP session handshake |
| Herdr terminal | Install and start Herdr | Runtime and Unix socket forwarding; CLI agents inside terminals manage their own models |

Checks do not send model prompts or prove successful model inference. Reading a
model list is distinct from validating that model's credentials. The wizard shows
these boundaries directly, including login checks deferred to the first message.

The packaged app includes the first-party bridge installer. **Install / update
bridge** installs only the selected adapter's dependencies: OMP needs Python 3,
Qoder also needs Node.js/npm and its SDK, and DeepSeek uses a pinned Python wheel.
The operation does not stop a running service. An older bridge without `/setup`
needs an update and a manual restart after its active tasks finish. Cancelling
setup closes local checks; it does not undo remote installation or stop agents.

Kimi defaults to remote loopback port `58627` and token file
`~/.kimi-code/server.token`. Change either in **Advanced settings**. **Start Kimi
Web** starts a background service with a private log at
`~/.local/state/perch/kimi-web.log`; it does not replace an existing service or
change its permissions. Custom token paths must match the service's own configuration.

### Existing machines and connection problems

Open **Environment → machine gear** (or select a saved machine in Settings) to
check an agent, enable another, adjust Kimi settings, or disable other automatic
connections. New machines connect only the agent chosen in setup. Older saved
machines retain their previous enabled agents and IDs until edited; existing
sessions and drafts stay associated with those IDs. Removing the last machine
returns to the empty setup screen without stopping remote tasks.

The environment menu and task composer display connection errors directly and
provide **Check and repair connection**. Only configured native agents are shown
in the task composer. Kimi does not require Herdr.

See [Kimi details](KIMI.md) and [native bridge details](NATIVE-AGENTS.md) for protocol
versions and recovery boundaries.

## Daily use

Use `⌘N` to create a native conversation and select an agent and remote directory.
Use task groups for related work and the sidebar for navigation. Hover a session
for pin and archive actions; right-click for a local display name, grouping and
deletion. Active work cannot be quick-archived. `⌘T` opens a remote terminal.

Kimi and remote OMP send running-task messages as steering by default. Choose
“Send next turn” from the adjacent menu to queue instead. Pending text and its
delivery state remain visible in the conversation. Qoder CN / dsh queue for the
next turn. Update the remote native bridge to enable OMP steering.
Local Agent setup currently discovers OMP and checks its version; local native
execution is not available yet. Remote file viewing and read-only Git diff are
experimental. Configure models and credentials in each agent's CLI.

Closing a local view disconnects the client. Ending a remote terminal or deleting
history is a separate explicit action. Perch does not take over another attached
Herdr client or enable permission bypass automatically.

Workspace layout is saved locally. Drafts and pending attachments currently live
only for the current App process. Remote session survival depends on its runtime;
see the adapter documentation for disconnect, restart and history boundaries.
