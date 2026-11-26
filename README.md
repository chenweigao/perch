<h1 align="center">Perch</h1>
<p align="center"><strong>A home for your coding agents.</strong><br>A native Mac workspace for local and remote agent workflows.</p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a> · <a href="docs/GETTING-STARTED.md">Get started</a> · <a href="#status">Project status</a></p>

Run Kimi, Codex or Antigravity on your Mac, or connect to supported agents over SSH. Perch brings
conversations, tasks, tool output and approvals into one native workspace, so you
can read the result, inspect the work and decide what happens next.

Built with SwiftUI, AppKit and Ghostty, with native text editing, keyboard shortcuts
and system Liquid Glass on macOS 26.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/perch-overview-dark.png">
  <img alt="Perch workspace, native view render: sidebar, conversation and integrated changes inspector with demo content" src="docs/images/perch-overview.png">
</picture>

| Start with context | Keep the work in view |
| --- | --- |
| [![Choose a project, model and reasoning effort before starting](docs/images/perch-new-session.png)](docs/images/perch-new-session.png) | [![Session overview, plan and environment in the integrated right panel](docs/images/perch-tool-details.png)](docs/images/perch-tool-details.png) |
| Pick a machine, project and agent above the composer; model and permissions sit in it. | Read the answer first; the right panel keeps the session overview, plan and environment. |

*Native view renders of the production workspace (2026-11-26) with synthetic demo data, not live sessions. The capture
omits the system Liquid Glass blur, so the backdrop is approximated by a smooth gradient.
[Light appearance](docs/images/perch-overview.png) · [Dark appearance](docs/images/perch-overview-dark.png) · [Focused reading](docs/images/perch-progress.png) · [Asset sources](docs/showcase/README.md)*

## Why Perch

- **Native conversations.** Streaming replies, Markdown (including TeX math typeset natively by SwiftMath), thinking and tool results, with details that expand when you need them.
- **Start with the right context.** Choose a local or remote environment, search recent projects, and select model, reasoning effort and permissions before sending.
- **A workspace for your tasks.** Group sessions, pin important work, archive finished conversations and return to your previous workspace.
- **Know what needs you.** See running tasks, pending questions and results waiting to be read, plus Kimi's subagents (including their own transcripts), background tasks with their output tails, and the session's edit churn (+/− per file) in the activity bar.
- **Keep your CLI workflow.** Use native chat for supported agents and Ghostty terminals for CLI sessions through Herdr.
- **Inspect the work.** Read Markdown, source, images, PDF, tables and standalone HTML, then inspect Git changes alongside the conversation (experimental).
- **Keep projects moving.** Project goals and outcomes, a floating companion, scoped search, revision-bound delivery records and one-time follow-ups. See [workspace workflows](docs/WORKSPACE.md) for limits and background behavior.
- **Remote execution, local control.** Files and tools run on your server. Closing the Mac app leaves managed remote sessions running.
- **Explicit permission modes.** Choose adapter-specific defaults and per-task overrides; high-risk modes require confirmation. Kimi, Qoder and Claude Code can change for a later message or turn, while OMP and Codex are fixed when a session is created.

## Agent connections

| Agent / workflow | Connection | Experience |
| --- | --- | --- |
| Kimi Code | Kimi Web API over SSH | Native conversation |
| Oh My Pi (OMP) | RPC through the remote bridge | Native conversation |
| Qoder CN | Official Agent SDK through the remote bridge | Native conversation |
| Qoder | Official Agent SDK through the remote bridge | Native conversation |
| Claude Code | Official Agent SDK through the remote bridge | Native conversation |
| Antigravity (`agy`) | ACP through the remote bridge | Native conversation |
| DeepSeek Harness (dsh) | ACP through the remote bridge | Native conversation |
| Codex | `codex app-server` JSON-RPC over stdio through the remote bridge | Native conversation |
| Other CLI agents | Herdr + SSH | Terminal |

Native integrations share the same conversation UI. Additional RPC, SDK or ACP
adapters are welcome; arbitrary protocol compatibility is not automatic.
See [Kimi setup](docs/KIMI.md) and [OMP / Qoder CN / Qoder / dsh / Codex / Claude Code / Antigravity setup](docs/NATIVE-AGENTS.md)
for tested versions and recovery limits. Agent credentials and model configuration
stay with the CLI; Perch does not connect directly to model providers.

Local Kimi, Codex and Antigravity conversations are available; other local agents remain
discovery-only. See [local agents](docs/LOCAL-AGENTS.md). Kimi, remote OMP and Codex support steering during a running task, with an
explicit next-turn option. Codex keeps its native thread ID and history, takes model
and reasoning-effort choices from `model/list`, and surfaces every app-server approval
or question for an explicit response. Qoder CN / Qoder / dsh / Claude Code support stopping and next-turn
queueing. Pending messages appear in the conversation until runtime history confirms
them. Existing Herdr sessions remain terminal sessions.

## Download

Grab the zipped app from [Releases](https://github.com/chenweigao/perch/releases). The
app is ad-hoc signed (no Apple notarization): on first launch, right-click → Open.

## Build and run

Requires macOS 26+ and a Swift toolchain with the macOS 26 SDK (Xcode 26 or newer).
The current build has been tested on Apple Silicon. A remote SSH host and the
corresponding agent runtime are required for remote sessions.

```sh
./scripts/build.sh
open build/Perch.app
```

For local work, start with [local Kimi, Codex or Antigravity setup](docs/LOCAL-AGENTS.md).
For remote work, choose **Connect a remote machine** on the home screen, or **Environment → +**.
The setup wizard verifies SSH, checks your chosen agent, offers installation and
login actions, then lets you browse a remote directory and start your first task.
Kimi's port and token-file path are editable in Advanced settings. Fresh installs
start without a preset host. See the [setup guide](docs/GETTING-STARTED.md).

`⌘N` new conversation · `⌘K` search · `⌃⌥P` companion · `Return` send · `Shift Return` new line

The interface follows the system language, with 简体中文 and English available
under Settings → Language; the sidebar and its flows are bilingual first, other
areas may still mix languages while translations catch up.

## Status

Early source preview. Long-session responsiveness and recovery still need work;
this is not a stable release. File previews and Git review/write workflows are experimental. Support varies by agent; check the adapter documentation before
relying on a workflow. Builds use local ad-hoc signing; notarized downloads are
not available yet.

## Contributing

Bug reports, focused fixes and agent adapters are welcome. Start with
[CONTRIBUTING.md](CONTRIBUTING.md). Please use synthetic conversations in reports
and screenshots, and remove credentials and private paths.

## License

MIT. Third-party components retain their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md).
