import AppKit
import Foundation
import WorkbenchCore

/// Real WorkbenchModel checks in an isolated app domain. Never call start():
/// saving setup before start must not launch SSH or contact a running agent.
@main struct HostLifecycleChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain.hasPrefix("dev.agentworkbench.hostqa."))
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(domain)
        let workspaceURL = directory.appendingPathComponent("workspace.json")

        switch CommandLine.arguments[1] {
        case "seed":
            let empty = WorkbenchModel()
            precondition(!empty.configuredEnvironment && empty.connections.isEmpty && empty.selectedConnection == nil)
            precondition(UserDefaults.standard.string(forKey: "defaultHostID") == nil)
            let host = SSHHost(name: "Fixture", destination: "fixture.invalid", enabledAgents: [.kimi], kimiPort: 60001)
            let launch = TaskLaunchDefaults(hostID: host.id, provider: .kimi, directory: "/tmp", model: "fixture/model")
            try empty.finishSetup(host, launch: launch, startTask: true)
            precondition(empty.selectedHostID == host.id && empty.kimi.host == host && empty.pendingSetupLaunch)
            precondition(empty.selectedConnection?.wantsConnection == false, "Kimi setup must not connect Herdr")
            empty.setupDismissed()
            precondition(empty.draftingNewTask && empty.launchAfterSetup == launch)
            let reference = SessionReference(hostID: host.id, terminalID: "fixture-terminal")
            var workspace = LocalWorkspace()
            workspace.pinned = [SavedTerminal(session: reference, title: "Fixture terminal")]
            workspace.starred = [reference]
            workspace.selectedTerminalID = reference.id; workspace.destination = .session
            try WorkspaceFile.save(workspace, to: workspaceURL)
            empty.native.drafts["fixture-native"] = "未发送的草稿"
            empty.kimi.drafts["fixture-kimi"] = "Kimi draft"
            try empty.flushDrafts()
            let nativeProbe = NativeAgentConnection(setupHost: host)
            let kimiProbe = KimiConnection(setupHost: host)
            precondition(nativeProbe.drafts.isEmpty && nativeProbe.queue.allItems.isEmpty)
            precondition(kimiProbe.drafts.isEmpty && kimiProbe.selectedId == nil)
            UserDefaults.standard.synchronize()
            print("PASS: empty first run, selected-agent setup and first-task handoff")

        case "restart":
            let saved = try WorkspaceFile.load(from: workspaceURL)
            let model = WorkbenchModel()
            precondition(model.configuredEnvironment && model.connections.count == 1)
            precondition(model.kimi.host.kimiPort == 60001 && model.kimi.host.enabledAgents == [.kimi])
            precondition(model.selectedConnection?.id == saved.pinned[0].session.hostID)
            precondition(model.selectedReference == saved.pinned[0].session)
            precondition(model.workspace.starred == saved.starred)
            precondition(model.native.drafts["fixture-native"] == "未发送的草稿")
            precondition(model.kimi.drafts["fixture-kimi"] == "Kimi draft")
            print("PASS: restart restores endpoint settings, session, pins and drafts")

        case "removal":
            let a = SSHHost(name: "A", destination: "fixture-a.invalid")
            let b = SSHHost(name: "B", destination: "fixture-b.invalid")
            let c = SSHHost(name: "C", destination: "fixture-c.invalid")
            // Saved lists from older releases retain their IDs and configured state.
            UserDefaults.standard.set(try JSONEncoder().encode([a, b, c]), forKey: "hosts")
            let terminal = SessionReference(hostID: c.id, terminalID: "fixture-c-terminal")
            var workspace = LocalWorkspace()
            workspace.pinned = [SavedTerminal(session: terminal, title: "C terminal")]
            workspace.selectedTerminalID = terminal.id
            workspace.destination = .session
            try WorkspaceFile.save(workspace, to: workspaceURL)
            let model = WorkbenchModel()
            precondition(model.configuredEnvironment && model.connections.map(\.host) == [a, b, c])
            precondition(model.kimi.host.id == a.id && model.selectedConnection?.id == c.id)
            model.removeHost(a)
            precondition(model.selectedReference == terminal && model.selectedConnection?.id == c.id,
                         "removing A must not redirect C's terminal actions to B")
            precondition(model.kimi.host.id == c.id && model.native.host.id == c.id)
            model.removeHost(c)
            precondition(model.selectedReference == nil && model.selectedConnection?.id == b.id)
            precondition(model.showDashboard && model.openedSessions.isEmpty)
            model.removeHost(b)
            precondition(model.connections.isEmpty && !model.configuredEnvironment && model.selectedConnection == nil)
            let persisted = try JSONDecoder().decode([SSHHost].self, from: UserDefaults.standard.data(forKey: "hosts")!)
            precondition(persisted.isEmpty)
            model.shutdown()
            print("PASS: removing another/current/last host preserves the correct target and saved list")

        default: fatalError("Unknown check phase")
        }
        fflush(stdout)
        // No run loop: queued Combine callbacks cannot initiate background work.
        exit(0)
    }
}
