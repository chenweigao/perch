import Foundation
import WorkbenchCore

@main
struct ProtocolTests {
    static func main() async throws {
        setbuf(stdout, nil)
        try checkConversationPresentation()
        checkCompactionSummaryDisplay()
        try checkActivitySummaries()
        try checkTaskRecaps()
        try checkSessionNaming()
        try checkToolVisibility()
        try checkConversationTodos()
        try checkConversationActivity()
        checkConversationTiming()
        try checkWorkflow()
        checkConversationRowGeometry()
        checkReplyDocument()
        checkReplyTableGeometry()
        try checkNativeAgents()
        try checkIncrementalLoading()
        try checkKimiProtocol()
        try checkKimiTasks()
        try checkKimiTranscript()
        try await checkKimiAPILifecycle()
        try checkKimiPrompts()
        try checkUnifiedWorkspace()
        try checkSessionManagement()
        try checkBatchArchive()
        try checkRunControl()
        try checkConnectivity()
        try await checkRemoteSetup()
        try checkDashboard()
        checkTaskGroup()
        checkSidebar()
        try checkModelSelection()
        try checkSlashCommands()
        try await checkRemoteFileViewer()
        try await checkRemoteGitDiff()
        let checks = ProtocolTests()
        checks.testPreviewAndPinnedTabs()
        try checks.testWorkspacePersistenceAndReviewRevision()
        try checks.testSnapshotMatchesHerdr09EnvelopeAndKeepsUnknownStatus()
        checks.testRemoteErrorIsNotPresentedAsAnEmptySessionList()
        try await checks.testShellQuotingPreservesHostileTextLiterally()
        checks.testRejectsSSHOptionInjection()
        try await checks.testAttachUsesRemoteBinaryAndDoesNotTakeOverAnotherClient()
        try await checks.testLiveSnapshotWhenExplicitlyRequested()
        print("PASS: protocol decoding, error propagation, shell argument isolation, SSH destination validation, attach contract")
    }
    func testPreviewAndPinnedTabs() {
        var tabs = TerminalTabs()
        tabs.open("a")
        tabs.open("b")
        expectEqual(tabs.ids, ["b"])
        expectEqual(tabs.previewID, "b")
        tabs.pin("b")
        tabs.open("c")
        tabs.open("b")
        expectEqual(tabs.ids, ["b", "c"])
        expectEqual(tabs.previewID, "c")
        tabs.open("new", pinned: true)
        expectEqual(tabs.ids, ["b", "c", "new"])
        tabs.open("d")
        expectEqual(tabs.ids, ["b", "new", "d"])
        tabs.open("d", pinned: true)
        expectEqual(tabs.previewID, nil)
        tabs.close("d")
        expectEqual(tabs.selectedID, "new")
        tabs.showOverview()
        expectEqual(tabs.selectedID, nil)
        expectEqual(tabs.ids, ["b", "new"])
        tabs.open("preview")
        tabs.close("preview")
        expectEqual(tabs.previewID, nil)
        tabs.restoreOrder(["new", "b"])
        expectEqual(tabs.ids, ["new", "b"])
        print("PASS: preview replacement, pinning, existing tabs, explicit new tabs, close, overview")
    }

    func testWorkspacePersistenceAndReviewRevision() throws {
        let hostA = UUID(), hostB = UUID()
        let refA = SessionReference(hostID: hostA, terminalID: "same")
        let refB = SessionReference(hostID: hostB, terminalID: "same")
        expectFalse(refA.id == refB.id)
        func pane(revision: UInt64, status: String) throws -> Pane {
            let value: [String: Any] = ["pane_id": "p1", "terminal_id": "same", "workspace_id": "w1", "tab_id": "t1", "cwd": "/tmp", "agent_status": status, "revision": revision]
            return try JSONDecoder().decode(Pane.self, from: JSONSerialization.data(withJSONObject: value))
        }
        var workspace = LocalWorkspace()
        workspace.groups = [WorkItemGroup(name: "验收任务", goal: "同一任务跨机器", nextStep: "检查结果", sessions: [refA, refB])]
        workspace.pinned = [SavedTerminal(session: refA, title: "QA")]
        workspace.selectedTerminalID = refA.id
        workspace.selectedGroupID = workspace.groups[0].id
        let done = try pane(revision: 4, status: "done")
        expectTrue(workspace.needsReview(done, on: hostA))
        workspace.markReviewed(done, on: hostA)
        expectFalse(workspace.needsReview(done, on: hostA))
        expectTrue(workspace.needsReview(done, on: hostB))
        expectTrue(workspace.needsReview(try pane(revision: 5, status: "done"), on: hostA))
        expectFalse(workspace.needsReview(try pane(revision: 5, status: "working"), on: hostA))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("awb-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("workspace.json")
        expectEqual(try WorkspaceFile.load(from: file), LocalWorkspace())
        try WorkspaceFile.save(workspace, to: file)
        expectEqual(try WorkspaceFile.load(from: file), workspace)
        let corrupted = Data("invalid-json".utf8)
        try corrupted.write(to: file)
        expectThrows(try WorkspaceFile.load(from: file))
        expectEqual(try Data(contentsOf: file), corrupted)
        print("PASS: task groups, cross-host identity, pinned scene persistence, reviewed revisions, corrupt-file preservation")
    }

    func testSnapshotMatchesHerdr09EnvelopeAndKeepsUnknownStatus() throws {
        let json = #"{"id":"read","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"w1","label":"code"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"研究"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term_one","workspace_id":"w1","tab_id":"w1:t1","cwd":"/home/user/code","foreground_cwd":"/home/user/code/project","agent":"kimi","agent_status":"future_state","terminal_title_stripped":"中文输入与终端"}],"agents":[]}}}"#
        let snapshot = try Wire.decode(SnapshotResult.self, from: Data(json.utf8)).snapshot
        expectEqual(snapshot.workspaces.first?.label, "code")
        expectEqual(snapshot.panes.first?.id, "term_one")
        expectEqual(snapshot.panes.first?.directory, "/home/user/code/project")
        expectEqual(snapshot.panes.first?.displayTitle, "研究")
        expectEqual(snapshot.panes.first?.terminalTitleStripped, "中文输入与终端")
        expectEqual(snapshot.panes.first?.status, "future_state")
    }

    func testRemoteErrorIsNotPresentedAsAnEmptySessionList() {
        let json = #"{"id":"read","error":{"code":"unsupported","message":"session.snapshot not supported"}}"#
        expectThrows(try Wire.decode(SnapshotResult.self, from: Data(json.utf8))) {
            expectEqual($0.localizedDescription, "session.snapshot not supported")
        }
    }

    func testShellQuotingPreservesHostileTextLiterally() async throws {
        let values = ["path with spaces", "one'two", "$(printf SUBSTITUTED)", "`printf EXECUTED`", "中文\n第二行"]
        let command = "printf '%s\\0' " + values.map(SSHCommand.quote).joined(separator: " ")
        let bytes = try await ProcessRunner.run("/bin/sh", ["-c", command])
        expectEqual(bytes, Data((values.joined(separator: "\0") + "\0").utf8))
    }

    func testRejectsSSHOptionInjection() {
        for target in ["-oProxyCommand=bad", "host\ncommand", "user host", ""] {
            expectThrows(try SSHCommand.validateDestination(target))
        }
        expectNoThrow(try SSHCommand.validateDestination("dev-env"))
        expectNoThrow(try SSHCommand.validateDestination("user@host.example"))
    }

    func testAttachUsesRemoteBinaryAndDoesNotTakeOverAnotherClient() async throws {
        let command = SSHCommand.attach(host: SSHHost(name: "Dev", destination: "dev-env"),
            binary: "/home/user/with space/herdr", terminalID: "term_1", controlPath: "/tmp/awb-control")
        let parsed = try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(command); printf '%s\\0' \"$@\""])
        let args = String(decoding: parsed, as: UTF8.self).split(separator: "\0").map(String.init)
        expectEqual(args.first, "/usr/bin/ssh")
        expectTrue(args.contains("StrictHostKeyChecking=yes"))
        expectFalse(command.contains("--takeover"))
        expectEqual(args.last, "exec '/home/user/with space/herdr' terminal attach 'term_1'")
    }

    func testLiveSnapshotWhenExplicitlyRequested() async throws {
        guard let host = ProcessInfo.processInfo.environment["WORKBENCH_LIVE_HOST"] else {
            print("SKIP: set WORKBENCH_LIVE_HOST for the read-only SSH integration check"); return
        }
        try SSHCommand.validateDestination(host)
        let data = try await ProcessRunner.run("/usr/bin/ssh", ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, "herdr api snapshot"])
        let snapshot = try Wire.decode(SnapshotResult.self, from: data).snapshot
        print("PASS: live SSH snapshot, Herdr \(snapshot.version), \(snapshot.panes.count) panes")
        expectFalse(snapshot.version.isEmpty)
        expectEqual(Set(snapshot.panes.map(\.terminalID)).count, snapshot.panes.count)
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected \(rhs), got \(lhs)", file: file, line: line)
}
func expectTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, "Expected true", file: file, line: line)
}
func expectFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!condition, "Expected false", file: file, line: line)
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, verify: (Error) -> Void = { _ in }) {
    do { _ = try expression(); fatalError("Expected an error") } catch { verify(error) }
}
func expectNoThrow<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { fatalError("Unexpected error: \(error)") }
}
