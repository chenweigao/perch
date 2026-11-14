import Foundation
import WorkbenchCore

@main
struct ProtocolTests {
    static func main() async throws {
        setbuf(stdout, nil)
        switch ProcessInfo.processInfo.environment["WORKBENCH_BENCH"] {
        case "1":
            try benchPresentationUpdate()
            return
        case "presentation-token":
            try benchPresentationTokenUpdates()
            return
        case "activity":
            try benchConversationActivity()
            return
        case "edit-lines":
            try benchEditLines()
            return
        case "streaming":
            try benchStreamingDelta()
            return
        case "real-stream":
            try benchPresentationRealStream()
            return
        case "real-transcript":
            try benchPresentationRealTranscript()
            return
        default:
            break
        }
        try checkStepAwareReading()
        try checkPhaseReading()
        try checkReadingLifecycle()
        checkStreamingTextReveal()
        checkReplyStreamSnapshot()
        checkReplyStreamParser()
        try checkConversationPresentation()
        try checkConversationProcessFold()
        try checkConversationPresentationModel()
        try checkConversationPresentationHistory()
        try checkConversationPresentationPaging()
        try checkWindowIdentityReuse()
        try checkSearchEntryReuse()
        try checkSearchCacheHoleProbes()
        checkCollapsedWhitespace()
        try checkTurnExcerpt()
        checkCompactionSummaryDisplay()
        try checkActivitySummaries()
        try checkTaskRecaps()
        checkReviewContext()
        try checkWorkspaceProgress()
        try checkGroupSuggestions()
        try checkSessionNaming()
        try checkCronFireEnvelope()
        try checkToolVisibility()
        try checkActivityToolsMatchProjection()
        try checkConversationTodos()
        try checkConversationActivity()
        try checkTurnStatus()
        try checkSessionTurn()
        try checkTaskContextFiles()
        checkTaskContextDetail()
        checkConversationTiming()
        try checkFrameHitchRecorder()
        checkAutoCompact()
        checkSafeLink()
        try checkSessionEditStats()
        try checkEditStatsLineCountScan()
        try checkEditLineScans()
        try checkEditLineDiffBoundaries()
        try checkEditToolClassification()
        try checkProjectCommands()
        checkAppVersionCheck()
        try checkWorkflow()
        checkAttentionRouting()
        try checkDocumentReading()
        checkConversationRowGeometry()
        checkReplyDocument()
        checkLinkScanContiguousUTF16()
        checkReplyMath()
#if canImport(AppKit)
        checkMathRendering()
#else
        print("SKIP: math rendering smoke check requires AppKit")
#endif
        checkReplyAlerts()
        checkReplySelection()
        checkReplyTableGeometry()
        checkTableSerialization()
        try checkNativeAgents()
        try checkNativeSubagents()
        try checkIncrementalLoading()
        try checkKimiProtocol()
        try checkKimiTasks()
        try checkKimiTranscript()
        try await checkKimiAPILifecycle()
        try await checkWebSocketHeartbeat()
        try checkKimiPrompts()
        try checkUnifiedWorkspace()
        try checkSessionManagement()
        try checkBatchArchive()
        try checkRunControl()
        try checkConnectivity()
        try checkRuntimeFreshness()
        try await checkRemoteSetup()
        try checkDashboard()
        try checkRestoreReport()
        checkTaskGroup()
        try checkUnifiedWorkbench()
        checkSidebar()
        try checkModelSelection()
        try checkSlashCommands()
        try await checkWorkspaceUpgrade()
        try await checkRemoteFileViewer()
        try await checkRemoteGitDiff()
        try await checkRemoteGitComparison()
        try await checkRemoteGitWrite()
        try await checkProjectFileReferences()
        let checks = ProtocolTests()
        checks.testPreviewAndPinnedTabs()
        try checks.testWorkspacePersistenceAndReviewRevision()
        try await checks.testShellQuotingPreservesHostileTextLiterally()
        checks.testRejectsSSHOptionInjection()
        try await checks.testShellCommandIsMultiplexedLoginShellInDirectory()
        print("PASS: protocol decoding, shell argument isolation, SSH destination validation")
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
        var workspace = LocalWorkspace()
        workspace.groups = [WorkItemGroup(name: "验收任务", goal: "同一任务跨机器", nextStep: "检查结果", sessions: [refA, refB])]
        workspace.pinned = [SavedTerminal(session: refA, title: "QA")]
        workspace.selectedTerminalID = refA.id
        workspace.selectedGroupID = workspace.groups[0].id
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
        print("PASS: task groups, cross-host identity, pinned scene persistence, corrupt-file preservation")
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

    func testShellCommandIsMultiplexedLoginShellInDirectory() async throws {
        let command = SSHCommand.shell(host: SSHHost(name: "Dev", destination: "dev-env"),
            directory: "/home/user/with space/it's", controlPath: "/tmp/awb-control")
        let parsed = try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(command); printf '%s\\0' \"$@\""])
        let args = String(decoding: parsed, as: UTF8.self).split(separator: "\0").map(String.init)
        expectEqual(args.first, "/usr/bin/ssh")
        expectTrue(args.contains("-tt"))
        expectTrue(args.contains("StrictHostKeyChecking=yes"))
        expectEqual(args.firstIndex(of: "-S").map { args[args.index(after: $0)] }, Optional("/tmp/awb-control"))
        expectTrue(args.contains("dev-env"))
        // The remote shell must receive the directory as one quoted word and expand $SHELL itself.
        expectEqual(args.last, "cd '/home/user/with space/it'\"'\"'s' && exec ${SHELL:-/bin/sh} -l")
        let remote = try await ProcessRunner.run("/bin/sh", ["-c", "cd \(SSHCommand.quote("/tmp")) && printf ok"])
        expectEqual(String(decoding: remote, as: UTF8.self), "ok")

        // "~/..." stays expandable on the remote side; empty means the login directory.
        let homeCommand = SSHCommand.shell(host: SSHHost(name: "Dev", destination: "dev-env"),
            directory: "~/code/project", controlPath: "/tmp/awb-control")
        let homeArgs = String(decoding: try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(homeCommand); printf '%s\\0' \"$@\""]), as: UTF8.self)
            .split(separator: "\0").map(String.init)
        expectEqual(homeArgs.last, "cd \"$HOME\"/'code/project' && exec ${SHELL:-/bin/sh} -l")
        let bareCommand = SSHCommand.shell(host: SSHHost(name: "Dev", destination: "dev-env"),
            directory: "", controlPath: "/tmp/awb-control")
        let bareArgs = String(decoding: try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(bareCommand); printf '%s\\0' \"$@\""]), as: UTF8.self)
            .split(separator: "\0").map(String.init)
        expectEqual(bareArgs.last, "exec ${SHELL:-/bin/sh} -l")
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
