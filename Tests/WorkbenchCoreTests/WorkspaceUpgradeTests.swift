import Foundation
import WorkbenchCore

func checkWorkspaceUpgrade() async throws {
    expectEqual(FilePreviewKind(path: "report.PDF"), .pdf)
    expectEqual(FilePreviewKind(path: "notes.md"), .markdown)
    expectEqual(FilePreviewKind(path: "photo.png").initialReadLimit, 16 * 1_048_576)
    expectEqual(DelimitedPreview("a,b\r\n\"x,y\",\"two\nlines\"\r\n\"say \"\"hi\"\"\",z").rows,
                [["a", "b"], ["x,y", "two\nlines"], ["say \"hi\"", "z"]])
    expectEqual(DelimitedPreview("\"\"").rows, [[""]])
    expectEqual(DelimitedPreview("").rows, [])
    expectEqual(DelimitedPreview("a\tb\n1\t2", delimiter: "\t").rows, [["a", "b"], ["1", "2"]])
    expectTrue(DelimitedPreview("a,b,c", columnLimit: 2).truncated)
    expectEqual(DelimitedPreview("a\nb\nc", rowLimit: 2).rows, [["a"], ["b"]])
    expectTrue(DelimitedPreview("a\nb\nc", rowLimit: 2).truncated)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perch-files-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = "prefix\n" + String(repeating: "中文", count: 30) + "\nlast line"
    let file = root.appendingPathComponent("quoted ' file.md")
    try Data(text.utf8).write(to: file)
    let tail = try await ProcessRunner.run("/bin/sh", ["-c", RemoteFileCommand.remoteCommand(path: file.path, limit: 29, fromEnd: true)])
    if case .text(let result, let truncated, let size) = try RemoteFileCommand.parse(tail, limit: 29, fromEnd: true) {
        expectTrue(truncated); expectEqual(size, text.utf8.count)
        expectTrue(result.hasSuffix("last line")); expectFalse(result.contains("�"))
    } else { fatalError("Expected UTF-8 tail preview") }
    let bytes = Data([0, 1, 2, 255])
    let binary = root.appendingPathComponent("image.png")
    try bytes.write(to: binary)
    let response = try await ProcessRunner.run("/bin/sh", ["-c", RemoteFileCommand.remoteCommand(path: binary.path)])
    expectEqual(RemoteFileCommand.body(in: response), bytes)

    let needle = "$(touch SHOULD_NOT_EXIST) ' needle"
    try Data(("start\n" + needle + "\nend").utf8).write(to: root.appendingPathComponent("search.txt"))
    let excluded = root.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
    try Data(needle.utf8).write(to: excluded.appendingPathComponent("ignored.txt"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path,
                                             withDestinationPath: file.path)
    try Data(repeating: 65, count: 1_048_577).write(to: root.appendingPathComponent("large.txt"))
    let found = try await ProcessRunner.run("/bin/sh", ["-c", ProjectFileSearchResult.command(directory: root.path, query: needle)])
    let result = try JSONDecoder().decode(ProjectFileSearchResult.self, from: found)
    expectEqual(result.hits.count, 1); expectEqual(result.hits.first?.line, 2)
    expectTrue(result.skipped >= 3); expectFalse(result.limited)
    expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))

    let host = UUID()
    let location = SidebarProjectLocation(hostID: host, directory: root.path, hostName: "Fixture")
    let reference = SessionReference(hostID: host, terminalID: "task", kind: .codex)
    func session(_ section: WorkQueueSection, online: Bool = true, archived: Bool = false, updated: Double = 100) -> WorkspaceSession {
        WorkspaceSession(reference: reference, title: "Task", directory: root.path, hostName: "Fixture", detail: "",
                         online: online, section: section, canMarkReviewed: false, archived: archived, updatedAt: updated)
    }
    var rule = FollowUpRule(session: session(.running), trigger: .time, dueAt: Date(timeIntervalSince1970: 200),
                            idleMinutes: 5, prompt: "continue", now: Date(timeIntervalSince1970: 100))
    let now = Date(timeIntervalSince1970: 401)
    expectTrue(rule.isDue(session: session(.running), now: now))
    expectFalse(rule.isDue(session: session(.attention), now: now))
    expectFalse(rule.isDue(session: session(.running, online: false), now: now))
    expectFalse(rule.isDue(session: session(.running, archived: true), now: now))
    expectFalse(rule.isDue(session: session(.running), now: Date(timeIntervalSince1970: 199)))
    rule.trigger = .nextResult
    expectFalse(rule.isDue(session: session(.review), now: now))
    expectTrue(rule.isDue(session: session(.review, updated: 110), now: now))
    rule.trigger = .inactivity
    expectTrue(rule.isDue(session: session(.running), now: now))
    expectFalse(rule.isDue(session: session(.running, updated: 400), now: now))
    rule.status = .needsReview
    expectFalse(rule.isDue(session: session(.running), now: now))
    for status in [FollowUpStatus.queued, .notified, .cancelled] {
        rule.status = status; expectFalse(rule.isDue(session: session(.running), now: now))
    }
    rule.status = .pending

    let payload = #"{"url":"https://github.com/example/repo/pull/1","state":"OPEN","headRefOid":"abc","statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"}]}"#
    let snapshot = try PullRequestSnapshot.parse(Data(payload.utf8), now: now)
    expectEqual(snapshot.head, "abc"); expectEqual(snapshot.checks.first?.state, "SUCCESS")
    var delivery = DeliveryRecord(project: location, title: "Preview", source: reference)
    delivery.revision = "abc"; delivery.snapshot = snapshot
    delivery.accepted = true; delivery.acceptedRevision = "abc"
    expectTrue(delivery.acceptanceCurrent)
    delivery.revision = "def"
    expectFalse(delivery.evidenceMatchesHead); expectFalse(delivery.acceptanceCurrent)
    expectThrows(try PullRequestSnapshot.command(directory: root.path, url: "file:///tmp/pr"))
    expectThrows(try PullRequestSnapshot.command(directory: root.path, url: "https://github.com/example/repo/issues/1"))

    var workspace = LocalWorkspace()
    workspace.followUps = [rule]; workspace.followedSessions = [reference]
    workspace.deliveries = [delivery]; workspace.projectBriefs[location.id] = ProjectBrief()
    workspace.companionDrafts[reference.id] = "unfinished reply"
    let encoded = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(LocalWorkspace.self, from: encoded)
    expectEqual(decoded, workspace); expectEqual(decoded.followUps[0].messageID, rule.messageID)
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["followUps", "followedSessions", "deliveries", "projectBriefs", "companionDrafts"] { legacy.removeValue(forKey: key) }
    let migrated = try JSONDecoder().decode(LocalWorkspace.self, from: JSONSerialization.data(withJSONObject: legacy))
    expectTrue(migrated.followUps.isEmpty && migrated.deliveries.isEmpty && migrated.companionDrafts.isEmpty)
    print("PASS: bounded file previews/search, workflow persistence, follow-up gates and revision-bound acceptance")
}
