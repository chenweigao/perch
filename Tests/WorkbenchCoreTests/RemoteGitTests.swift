import Foundation
import WorkbenchCore

/// Runs the real git scripts against a throwaway local repository, so quoting,
/// external-diff refusal, truncation and non-repository handling are checked
/// without touching any remote host or the user's own repositories.
func checkRemoteGitDiff() async throws {
    let statusTemplate = RemoteGitCommand.statusCommand(directory: "/x")
    expectTrue(statusTemplate.contains("--porcelain=v1"))
    expectTrue(statusTemplate.contains("worktree list --porcelain -z"))
    expectTrue(statusTemplate.contains("GIT_OPTIONAL_LOCKS=0"))
    expectTrue(statusTemplate.contains("core.fsmonitor=false"))
    let arguments = RemoteGitCommand.sshArguments(destination: "dev-env", command: statusTemplate)
    expectTrue(arguments.contains("BatchMode=yes"))
    expectTrue(arguments.contains("StrictHostKeyChecking=yes"))
    expectEqual(arguments[arguments.count - 2], "dev-env")

    let hostile = "/tmp/a b/$(printf SUBSTITUTED)/`printf EXECUTED`/-rf/中文"
    let secondHostile = "/tmp/second ' quote"
    let statusCommand = RemoteGitCommand.statusCommand(directories: [hostile, secondHostile])
    let statusOperands = try await ProcessRunner.run(
        "/bin/sh", ["-c", "set -- \(statusCommand); printf '%s\\0%s\\0' \"$5\" \"$6\""])
    expectEqual(String(decoding: statusOperands, as: UTF8.self), hostile + "\0" + secondHostile + "\0")

    let command = RemoteGitCommand.diffCommand(directory: hostile, path: hostile, staged: false)
    let echoed = try await ProcessRunner.run(
        "/bin/sh", ["-c", "set -- \(command); printf '%s\\0%s\\0' \"$5\" \"$6\""])
    expectEqual(String(decoding: echoed, as: UTF8.self), hostile + "\0" + hostile + "\0")
    expectTrue(command.contains("--no-ext-diff"))
    expectTrue(command.contains("--no-textconv"))
    expectTrue(command.contains("diff.external="))
    expectTrue(command.contains("--"))

    let messages = try KimiWire.decoder().decode([KimiMessage].self, from: Data(#"""
    [
      {"id":"old","role":"assistant","created_at":"2026-09-23T00:00:00Z","content":[
        {"type":"tool_use","input":{"cwd":"/session/old","path":"Sources/Old.swift"}}
      ]},
      {"id":"new","role":"assistant","created_at":"2026-09-23T00:01:00Z","content":[
        {"type":"tool_use","input":{"workdir":"relative-worktree","file_path":"Sources/New.swift"}}
      ]}
    ]
    """#.utf8))
    let liveTools = try KimiWire.decoder().decode([KimiLiveTool].self, from: Data(#"""
    [
      {"tool_call_id":"live","name":"Read","args":{"working_directory":"/session/live","path":"Tests/Live.swift"}},
      {"tool_call_id":"shell","name":"Bash","args":{"command":"git worktree add /secret/path"}}
    ]
    """#.utf8))
    let hints = RemoteGitDirectoryHints.candidates(
        messages: messages, liveTools: liveTools, sessionDirectory: "/session/base", limit: 7)
    expectEqual(hints, [
        "/session/live",
        "/session/live/Tests/Live.swift",
        "/session/live/Tests",
        "/session/base/relative-worktree",
        "/session/base/relative-worktree/Sources/New.swift",
        "/session/base/relative-worktree/Sources",
        "/session/base"
    ])
    expectEqual(Set(hints).count, hints.count)
    expectFalse(hints.contains { $0.contains("secret") })
    expectEqual(RemoteGitDirectoryHints.candidates(
        messages: messages, sessionDirectory: "/session/base", limit: 1), ["/session/base"])

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("awb-remote-git-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("仓库 repo")
    let linked = root.appendingPathComponent("linked 工作树")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    func git(_ arguments: [String], at requestedDirectory: URL? = nil) async throws {
        let directory = requestedDirectory ?? repo
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path] + arguments)
    }
    func status(at requestedDirectories: [String]? = nil) async throws -> RemoteGitStatus {
        let directories = requestedDirectories ?? [repo.path]
        let data = try await ProcessRunner.run(
            "/bin/sh", ["-c", RemoteGitCommand.statusCommand(directories: directories)])
        return try RemoteGitCommand.parseStatus(data)
    }
    func diff(at requestedDirectory: String? = nil, path: String, staged: Bool,
              limit: Int = RemoteGitCommand.diffLimit) async throws -> RemoteGitDiff {
        let script = RemoteGitCommand.diffCommand(
            directory: requestedDirectory ?? repo.path, path: path, staged: staged, limit: limit)
        return try RemoteGitCommand.parseDiff(
            try await ProcessRunner.run("/bin/sh", ["-c", script]), limit: limit)
    }

    let plain = try await ProcessRunner.run(
        "/bin/sh", ["-c", RemoteGitCommand.statusCommand(directory: root.path)])
    expectEqual(try RemoteGitCommand.parseStatus(plain), .notARepository)
    expectEqual(try RemoteGitCommand.parseDiff(
        try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.diffCommand(
            directory: root.path, path: "x", staged: false)])), .notARepository)
    let missingPath = root.appendingPathComponent("absent").path
    let missing = try await ProcessRunner.run(
        "/bin/sh", ["-c", RemoteGitCommand.statusCommand(directory: missingPath)])
    expectEqual(try RemoteGitCommand.parseStatus(missing), .notARepository)

    try await git(["init", "--quiet", "-b", "main"])
    try await git(["config", "user.email", "fixture@example.test"])
    try await git(["config", "user.name", "Fixture"])
    try Data("第一行\n第二行\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try Data("keep\n".utf8).write(to: repo.appendingPathComponent("stable.txt"))
    try await git(["add", "."])
    try await git(["commit", "--quiet", "-m", "fixture"])

    guard case .clean(let initialRoot, let initialWorktrees) = try await status()
    else { fatalError("Expected a clean repository") }
    expectEqual(URL(fileURLWithPath: initialRoot).resolvingSymlinksInPath().path,
                repo.resolvingSymlinksInPath().path)
    expectEqual(initialWorktrees.count, 1)
    expectTrue(initialWorktrees[0].current)
    expectEqual(initialWorktrees[0].branchName, "main")

    let tildeCommand = RemoteGitCommand.statusCommand(directory: "~/\(repo.lastPathComponent)")
    let tildeData = try await ProcessRunner.run(
        "/bin/sh", ["-c", "HOME=\(SSHCommand.quote(root.path)) \(tildeCommand)"])
    guard case .clean(let tildeRoot, _) = try RemoteGitCommand.parseStatus(tildeData)
    else { fatalError("Expected tilde directory expansion") }
    expectEqual(URL(fileURLWithPath: tildeRoot).resolvingSymlinksInPath().path,
                repo.resolvingSymlinksInPath().path)

    try await git(["worktree", "add", "--quiet", "-b", "feature/linked", linked.path])
    try Data("changed only in linked worktree\n".utf8).write(to: linked.appendingPathComponent("stable.txt"))

    guard case .clean(_, let mainWorktrees) = try await status()
    else { fatalError("The main checkout must remain clean") }
    expectEqual(mainWorktrees.count, 2)
    expectTrue(mainWorktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path }?.current == true)
    expectEqual(mainWorktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == linked.resolvingSymlinksInPath().path }?.branchName, "feature/linked")

    guard case .changes(let linkedRoot, let linkedWorktrees, let linkedEntries) = try await status(at: [linked.path])
    else { fatalError("Expected changes in the linked worktree") }
    expectEqual(URL(fileURLWithPath: linkedRoot).resolvingSymlinksInPath().path,
                linked.resolvingSymlinksInPath().path)
    expectTrue(linkedWorktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == linked.resolvingSymlinksInPath().path }?.current == true)
    expectTrue(linkedEntries.contains { $0.path == "stable.txt" && $0.hasUnstaged })
    guard case .text(let linkedDiff, false) = try await diff(at: linked.path, path: "stable.txt", staged: false)
    else { fatalError("Expected linked worktree diff") }
    expectTrue(linkedDiff.contains("+changed only in linked worktree"))

    guard case .changes(let fallbackRoot, _, _) = try await status(at: [missingPath, linked.path])
    else { fatalError("Expected status candidate fallback") }
    expectEqual(URL(fileURLWithPath: fallbackRoot).resolvingSymlinksInPath().path,
                linked.resolvingSymlinksInPath().path)

    var fixture = Data("kind=status-v2\n--\n".utf8)
    fixture.append(Data((
        "/repo\0\0" +
        "worktree /repo\0HEAD 11111111\0branch refs/heads/main\0locked held by test\0\0" +
        "worktree /gone\0HEAD 22222222\0detached\0prunable gitdir missing\0\0" +
        "worktree /bare\0bare\0\0"
    ).utf8))
    guard case .clean(_, let fixtureWorktrees) = try RemoteGitCommand.parseStatus(fixture)
    else { fatalError("Expected clean fixture status") }
    guard let locked = fixtureWorktrees.first(where: { $0.path == "/repo" }),
          let prunable = fixtureWorktrees.first(where: { $0.path == "/gone" }),
          let bare = fixtureWorktrees.first(where: { $0.path == "/bare" })
    else { fatalError("Missing parsed worktree fixture") }
    expectTrue(locked.current)
    expectTrue(locked.locked)
    expectEqual(locked.lockedReason, "held by test")
    expectTrue(locked.selectable)
    expectTrue(prunable.detached)
    expectEqual(prunable.prunableReason, "gitdir missing")
    expectFalse(prunable.selectable)
    expectTrue(bare.bare)
    expectFalse(bare.selectable)

    try Data("第一行\n第二行 修改\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try await git(["add", "说明.md"])
    try Data("第一行\n第二行 修改\n第三行 未暂存\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try Data("新文件\n".utf8).write(to: repo.appendingPathComponent("未跟踪 file.txt"))
    try await git(["mv", "stable.txt", "renamed.txt"])

    guard case .changes(let repoRoot, let worktrees, let entries) = try await status()
    else { fatalError("Expected changes") }
    expectEqual(URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path,
                repo.resolvingSymlinksInPath().path)
    expectEqual(worktrees.count, 2)
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    guard let note = byPath["说明.md"] else { fatalError("Missing the edited file") }
    expectTrue(note.hasStaged)
    expectTrue(note.hasUnstaged)
    expectFalse(note.untracked)
    guard let untracked = byPath["未跟踪 file.txt"] else { fatalError("Missing the untracked file") }
    expectTrue(untracked.untracked)
    expectEqual(untracked.label, "未跟踪")
    expectFalse(untracked.hasStaged)
    guard let renamed = byPath["renamed.txt"] else { fatalError("Missing the renamed file") }
    expectEqual(renamed.originalPath, "stable.txt")
    expectEqual(renamed.indexStatus, "R")

    guard case .text(let unstaged, false) = try await diff(path: "说明.md", staged: false)
    else { fatalError("Expected unstaged text") }
    expectTrue(unstaged.contains("+第三行 未暂存"))
    expectFalse(unstaged.contains("+第二行 修改"))
    guard case .text(let staged, false) = try await diff(path: "说明.md", staged: true)
    else { fatalError("Expected staged text") }
    expectTrue(staged.contains("+第二行 修改"))
    expectFalse(staged.contains("+第三行 未暂存"))
    expectEqual(try await diff(path: "renamed.txt", staged: false), .empty)

    try await git(["config", "diff.external", "/bin/sh -c 'printf EXTERNAL_RAN'"])
    guard case .text(let guarded, _) = try await diff(path: "说明.md", staged: false)
    else { fatalError("Expected text") }
    expectFalse(guarded.contains("EXTERNAL_RAN"))
    try await git(["config", "--unset", "diff.external"])

    let binary = repo.appendingPathComponent("blob.bin")
    try Data([0x00, 0x01, 0x02, 0xff]).write(to: binary)
    try await git(["add", "blob.bin"])
    expectEqual(try await diff(path: "blob.bin", staged: true), .binary)

    let large = repo.appendingPathComponent("large.txt")
    try Data(String(repeating: "中文内容行\n", count: 4_000).utf8).write(to: large)
    try await git(["add", "large.txt"])
    guard case .text(let clipped, true) = try await diff(path: "large.txt", staged: true, limit: 2_000)
    else { fatalError("Expected a truncated diff") }
    expectTrue(clipped.utf8.count <= 2_000)
    expectFalse(clipped.contains("\u{FFFD}"))

    print("PASS: remote git worktree discovery and selection, status states, directory hints, staged/unstaged diffs, quoting, external-diff refusal, binary and truncation")
}
