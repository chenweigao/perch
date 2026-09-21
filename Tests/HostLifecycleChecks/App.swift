import AppKit
import Foundation
import WorkbenchCore

/// Real WorkbenchModel checks in an isolated app domain. Never call start() or
/// addHost(): the fixture must not launch SSH or contact a running agent.
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
            let model = WorkbenchModel()
            precondition(!model.configuredEnvironment)
            let host = model.connections[0].host
            let reference = SessionReference(hostID: host.id, terminalID: "fixture-terminal")
            var workspace = LocalWorkspace()
            workspace.pinned = [SavedTerminal(session: reference, title: "Fixture terminal")]
            workspace.starred = [reference]
            workspace.selectedTerminalID = reference.id
            workspace.destination = .session
            try WorkspaceFile.save(workspace, to: workspaceURL)
            model.native.drafts["fixture-native"] = "未发送的草稿"
            model.kimi.drafts["fixture-kimi"] = "Kimi draft"
            try model.flushDrafts()
            UserDefaults.standard.synchronize()
            print("PASS: first-run identity, workspace and drafts seeded")

        case "restart":
            let saved = try WorkspaceFile.load(from: workspaceURL)
            let model = WorkbenchModel()
            precondition(!model.configuredEnvironment, "restoring the built-in host must not dismiss setup")
            precondition(model.selectedConnection.id == saved.pinned[0].session.hostID)
            precondition(model.selectedReference == saved.pinned[0].session)
            precondition(model.workspace.starred == saved.starred)
            precondition(model.native.drafts["fixture-native"] == "未发送的草稿")
            precondition(model.kimi.drafts["fixture-kimi"] == "Kimi draft")
            print("PASS: separate launch restores the same host, selected session, pin and drafts")

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
            precondition(model.kimi.host.id == a.id && model.selectedConnection.id == c.id)
            model.removeHost(a)
            precondition(model.selectedReference == terminal && model.selectedConnection.id == c.id,
                         "removing A must not redirect C's terminal actions to B")
            precondition(model.kimi.host.id == c.id && model.native.host.id == c.id)
            model.removeHost(c)
            precondition(model.selectedReference == nil && model.selectedConnection.id == b.id)
            precondition(model.showDashboard && model.openedSessions.isEmpty)
            model.removeHost(b)
            precondition(model.connections.map(\.host) == [b] && model.managementError != nil)
            let persisted = try JSONDecoder().decode([SSHHost].self, from: UserDefaults.standard.data(forKey: "hosts")!)
            precondition(persisted == [b])
            model.shutdown()
            print("PASS: removing another/current/last host preserves the correct target and saved list")

        default: fatalError("Unknown check phase")
        }
        fflush(stdout)
        // No run loop: queued Combine callbacks cannot initiate background work.
        exit(0)
    }
}
