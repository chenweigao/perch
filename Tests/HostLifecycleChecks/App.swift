import AppKit
import Foundation
import WorkbenchCore

/// Real WorkbenchModel checks in an isolated app domain. All phases stay on
/// the main actor without yielding; queued connection tasks never launch SSH.
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
            model.startNewTask()
            precondition(model.draftingNewTask && model.selectedReference == saved.pinned[0].session,
                         "inline draft must preserve the selected session")
            model.select(saved.pinned[0].session.id)
            precondition(!model.draftingNewTask && model.selectedReference == saved.pinned[0].session,
                         "selecting a session must leave the draft")
            model.hostFilter = saved.pinned[0].session.hostID
            model.startNewTask()
            model.showHome()
            precondition(!model.draftingNewTask && model.showDashboard,
                         "returning home must leave the inline draft")
            precondition(model.hostFilter == saved.pinned[0].session.hostID,
                         "inline draft integration must preserve the workbench host scope")
            print("PASS: inline draft preserves selection, leaves on navigation and retains queue scope")
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

        case "connection-controls":
            let a = SSHHost(name: "A", destination: "fixture-a.invalid")
            let b = SSHHost(name: "B", destination: "fixture-b.invalid", autoConnectSSH: false, autoConnectHerdr: false)
            UserDefaults.standard.set(try JSONEncoder().encode([a, b]), forKey: "hosts")
            let model = WorkbenchModel()
            model.start()
            let aa = model.agentConnections(for: a.id)!
            let ba = model.agentConnections(for: b.id)!
            precondition(aa.kimi.connecting && aa.native.wantsConnection && model.connections[0].wantsConnection)
            precondition(!ba.kimi.connecting && !ba.native.wantsConnection && !model.connections[1].wantsConnection)
            model.activateAgentEnvironment(b.id)
            model.resumeConnectionsAfterWake()
            precondition(!ba.kimi.connecting && !ba.native.wantsConnection && !model.connections[1].wantsConnection)

            model.disconnectSSH(a.id)
            precondition(model.connections[0].wantsConnection, "SSH Agent disconnect must leave Herdr connected")
            model.disconnectHerdr(a.id)
            model.activateAgentEnvironment(a.id)
            model.resumeConnectionsAfterWake()
            precondition(!aa.kimi.connecting && !aa.native.wantsConnection && !model.connections[0].wantsConnection)
            precondition(model.connections[0].host.autoConnectSSH && model.connections[0].host.autoConnectHerdr,
                         "temporary disconnect must preserve launch preferences")

            model.setAutoConnect(true, for: b.id, herdr: true)
            precondition(model.connections[1].wantsConnection && !ba.kimi.connecting && !ba.native.wantsConnection)
            model.setAutoConnect(true, for: b.id, herdr: false)
            precondition(ba.kimi.connecting && ba.native.wantsConnection)
            model.setAutoConnect(false, for: b.id, herdr: true)
            precondition(!model.connections[1].wantsConnection && ba.kimi.connecting && ba.native.wantsConnection)
            model.setAutoConnect(false, for: b.id, herdr: false)
            precondition(!ba.kimi.connecting && !ba.native.wantsConnection)
            model.setAutoConnect(false, for: a.id, herdr: true)
            model.setAutoConnect(false, for: a.id, herdr: false)
            let setup = RemoteSetupController(host: model.connections[0].host)
            precondition(!setup.host.autoConnectSSH && !setup.host.autoConnectHerdr,
                         "editing the host must retain connection preferences")
            try model.finishSetup(setup.host, launch: nil, startTask: false)
            precondition(!aa.kimi.connecting && !aa.native.wantsConnection && !model.connections[0].wantsConnection)
            model.shutdown()
            UserDefaults.standard.synchronize()
            print("PASS: independent SSH/Herdr controls, immediate toggles, temporary disconnect, activation/wake and setup")

        case "connection-restart":
            let model = WorkbenchModel()
            precondition(model.connections.count == 2)
            model.start()
            for connection in model.connections {
                precondition(!connection.host.autoConnectSSH && !connection.host.autoConnectHerdr)
                let agents = model.agentConnections(for: connection.id)!
                precondition(!agents.kimi.connecting && !agents.native.wantsConnection && !connection.wantsConnection)
            }
            // Manual connection is available even when launch connection is off.
            let connection = model.connections[0]
            model.connectSSH(connection.id)
            connection.connect()
            let agents = model.agentConnections(for: connection.id)!
            precondition(agents.kimi.connecting && agents.native.wantsConnection && connection.wantsConnection)
            precondition(!connection.host.autoConnectSSH && !connection.host.autoConnectHerdr)
            model.shutdown()
            print("PASS: disabled launch preferences survive restart; manual reconnect remains available")

        default: fatalError("Unknown check phase")
        }
        fflush(stdout)
        // No run loop: queued Combine callbacks cannot initiate background work.
        exit(0)
    }
}
