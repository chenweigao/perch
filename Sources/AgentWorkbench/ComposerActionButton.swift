import SwiftUI
import WorkbenchCore

/// PI's primary action: a draft sends, an empty running composer stops.
struct ComposerActionButton: View {
    @UILocalization private var L
    let isRunning: Bool
    let isStopping: Bool
    let canSend: Bool
    let canStop: Bool
    var hasDraft = false
    /// False while disconnected or waiting for the user, even if the turn is open.
    var showsActivity = true
    /// A localization key ("Queue", "Steer", "Run command").
    var queuedSendTitle = "Queue"
    let onSend: () -> Void
    let onStop: () -> Void
    var onQueue: (() -> Void)? = nil

    private var showsStop: Bool { isRunning && !hasDraft }
    private var stopping: Bool { isRunning && isStopping }
    private var active: Bool { showsStop && canStop && showsActivity && !stopping }
    private var enabled: Bool { !stopping && (showsStop ? canStop : canSend) }
    private var title: String { stopping ? L("Stopping…") : showsStop ? L("Stop task") : L("Send") }
    /// The hint does what Return does; its tooltip names that key and ⌘Return.
    private var queuedSendHelp: String {
        switch queuedSendTitle {
        case "Steer": return onQueue == nil ? L("回车引导当前轮") : L("回车引导当前轮 · ⌘回车排到下一轮")
        case "Run command": return L("回车执行命令")
        default: return L("回车排到下一轮发送")
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            if isRunning && hasDraft && canSend && !stopping {
                if let onQueue {
                    // ⌘↩ is text, not a key equivalent: the composer already handles
                    // ⌘Return, and a pop-up button can fire its items' equivalents
                    // while closed, even when focus is elsewhere or mid-composition.
                    // The chevron keeps its size; it sits in the toolbar layout's send slot.
                    Menu {
                        Button(L("Send next turn") + "  ⌘↩", action: onQueue)
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("Send next turn")
                        .accessibilityLabel(L("Send next turn"))
                }
            }
            Button {
                if showsStop { onStop() } else { onSend() }
            } label: {
                ZStack {
                    Circle().fill(showsStop ? WorkbenchTheme.ink.opacity(0.16)
                                  : enabled ? WorkbenchTheme.accent : WorkbenchTheme.ink.opacity(0.10))
                    Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                        .font(.system(size: showsStop ? 14 : 15, weight: .semibold))
                        .foregroundStyle(showsStop ? WorkbenchTheme.ink
                                         : enabled ? WorkbenchTheme.actionGlyph : WorkbenchTheme.quiet)
                        .opacity(showsStop && !enabled ? 0.5 : 1)
                }.frame(width: 28, height: 28)
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
                .accessibilityValue(active ? L("Working…") : "")
                .accessibilityIdentifier("composer-primary-action")
                .help(isRunning && hasDraft ? queuedSendHelp : showsStop || stopping ? title : L("Return to send · Shift Return for a new line"))
        }
    }
}

struct ComposerAddButton: View {
    @UILocalization private var L
    var supportsFiles: Bool
    var disabled = false
    var onChoose: () -> Void = {}
    var body: some View {
        // An outlined circle (Qoder) whose left edge meets the draft's text
        // column, in the same ink as the model name beside it.
        Button(action: onChoose) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(WorkbenchTheme.Stroke.hairline, lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(.plain).foregroundStyle(WorkbenchTheme.ink)
            .disabled(disabled || !supportsFiles)
            .help(supportsFiles ? L("Add images or files") : L("Attachments are not supported by this agent connection"))
            .accessibilityLabel(supportsFiles ? L("Add images or files") : L("Attachments unavailable"))
    }
}
/// Environment details belong to the composer, without retargeting a running session.
struct ComposerEnvironmentMenu: View {
    let host: SSHHost
    let provider: String
    let directory: String

    var body: some View {
        Menu {
            Text(host.name)
            Text(provider)
            if !directory.isEmpty { Divider(); Text(directory) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: host.isLocal ? "desktopcomputer" : "server.rack")
                Text(host.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 88)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }.font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary).frame(height: 32)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("机器").accessibilityValue(host.name)
            .help(directory.isEmpty ? host.name : host.name + "\n" + directory)
    }
}

struct ComposerDeliveryHint: View {
    let sending: Bool
    let saveError: String?
    /// Character count of a long draft, so a wall of text is visible at a glance.
    var draftLength: Int = 0
    var body: some View {
        if let saveError { Text(saveError).font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.orange).textSelection(.enabled) }
        else if sending { Text("Sending…").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary) }
        else if draftLength >= 200 {
            Text("草稿 \(draftLength) 字").font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.tertiary)
        }
    }
}

@MainActor @Observable final class ComposerGitBranchCache {
    static let shared = ComposerGitBranchCache()
    private var branches: [String: String] = [:]
    @ObservationIgnored private var checked = Set<String>()

    private init() {}

    private func key(hostID: UUID, directory: String) -> String {
        "\(hostID.uuidString):\(directory)"
    }

    func branch(hostID: UUID, directory: String) -> String? {
        guard !directory.isEmpty else { return nil }
        return branches[key(hostID: hostID, directory: directory)]
    }

    func record(hostID: UUID, directory: String, branch: String?) {
        guard !directory.isEmpty else { return }
        let entryKey = key(hostID: hostID, directory: directory)
        checked.insert(entryKey)
        if let branch, !branch.isEmpty {
            branches[entryKey] = branch
        } else {
            branches.removeValue(forKey: entryKey)
        }
    }

    func load(host: SSHHost, directory: String) async {
        #if PERCH_ACCEPTANCE
        return
        #else
        guard !directory.isEmpty else { return }
        let entryKey = key(hostID: host.id, directory: directory)
        guard !checked.contains(entryKey) else { return }
        checked.insert(entryKey)
        do {
            let data: Data
            if host.isLocal {
                data = try await ProcessRunner.run("/usr/bin/git", ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"])
            } else {
                try SSHCommand.validateDestination(host.destination)
                let remoteCommand = "git -C \(SSHCommand.quote(directory)) rev-parse --abbrev-ref HEAD 2>/dev/null"
                data = try await ProcessRunner.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", host.destination, remoteCommand])
            }
            guard !Task.isCancelled else { return }
            let resolved = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                branches[entryKey] = resolved
            }
        } catch {
            // Non-repository or unreachable directories simply omit the branch badge.
        }
        #endif
    }
}

/// Third layer below the composer: host, working directory or project, Git branch, and context usage.
struct ComposerEnvironmentBar: View {
    @UILocalization private var L
    let host: SSHHost
    let provider: String
    let directory: String
    let budget: ContextBudget?
    var reportedAt: Double? = nil
    var isStale = false
    var autoCompactHost: UUID? = nil
    var autoCompactSession: String? = nil
    var sending = false
    var saveError: String? = nil
    var draftLength = 0
    @State private var presented = false
    private var branchCache: ComposerGitBranchCache { .shared }

    private var shortDirectory: String {
        guard !directory.isEmpty else { return "" }
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count <= 2 { return directory }
        return parts.suffix(2).joined(separator: "/")
    }

    var body: some View {
        let branch = branchCache.branch(hostID: host.id, directory: directory)
        HStack(spacing: 10) {
            Button { presented.toggle() } label: {
                // Qoder's footer: folder, machine, branch as separate icon-led
                // items with open space between them instead of dots.
                HStack(spacing: 16) {
                    if !shortDirectory.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: WorkbenchTheme.Composer.metadata + 1))
                            Text(shortDirectory)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack(spacing: 5) {
                        Image(systemName: host.isLocal ? "desktopcomputer" : "server.rack")
                            .font(.system(size: WorkbenchTheme.Composer.metadata + 1))
                        Text(host.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let branch, !branch.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: WorkbenchTheme.Composer.metadata + 1))
                            Text(verbatim: branch)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 140, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: WorkbenchTheme.Composer.text + 1))
                .foregroundStyle(WorkbenchTheme.quiet)
                .padding(.horizontal, 6)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(WorkbenchDisclosureButtonStyle())
            .accessibilityLabel("机器")
            .accessibilityValue([host.name, directory, branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            .help([host.name, directory, branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: host.isLocal ? "desktopcomputer" : "server.rack")
                            .foregroundStyle(.secondary)
                        Text(host.name).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(provider).foregroundStyle(.secondary)
                    }
                    if !host.isLocal, !host.destination.isEmpty {
                        Text(host.destination)
                            .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                            .foregroundStyle(WorkbenchTheme.quiet)
                            .textSelection(.enabled)
                    }
                    if !directory.isEmpty {
                        Divider()
                        Text(directory)
                            .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let branch, !branch.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                            Text(verbatim: branch)
                                .font(.system(size: WorkbenchTheme.Typography.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }.font(.system(size: WorkbenchTheme.Typography.body)).padding(14).frame(width: 300, alignment: .leading)
                    .onExitCommand { presented = false }
            }
            Spacer(minLength: 8)
            ComposerDeliveryHint(sending: sending, saveError: saveError, draftLength: draftLength)
            ContextMeter(budget: budget, reportedAt: reportedAt, isStale: isStale,
                         autoCompactHost: autoCompactHost, autoCompactSession: autoCompactSession)
        }
        .padding(.horizontal, 4)
        .task(id: "\(host.id.uuidString):\(directory)") {
            await branchCache.load(host: host, directory: directory)
        }
    }
}
