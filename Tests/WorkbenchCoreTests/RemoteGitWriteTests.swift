import Foundation
import WorkbenchCore

/// Exercises the write/history scripts against a throwaway local repository:
/// quoting stays literal, and stage/unstage/commit/switch/log/show round-trip
/// without touching any remote host or the user's own repositories.
func checkRemoteGitWrite() async throws {
    let hostile = "/tmp/a b/$(printf SUBSTITUTED)/`printf EXECUTED`/中文 'quote'"
    for command in [RemoteGitCommand.stageCommand(directory: hostile, path: hostile),
                    RemoteGitCommand.commitCommand(directory: hostile, message: hostile),
                    RemoteGitCommand.switchCommand(directory: hostile, branch: hostile)] {
        let echoed = try await ProcessRunner.run(
            "/bin/sh", ["-c", "set -- \(command); printf '%s\\0%s\\0' \"$5\" \"$6\""])
        expectEqual(String(decoding: echoed, as: UTF8.self), hostile + "\0" + hostile + "\0")
    }
    // Write scripts must not inherit the read-only lock bypass.
    precondition(!RemoteGitCommand.stageCommand(directory: "/x", path: "a").contains("GIT_OPTIONAL_LOCKS"))

    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("awb-remote-git-write-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("仓库 repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ arguments: [String]) async throws {
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + arguments)
    }
    func run(_ command: String) async throws -> Data {
        try await ProcessRunner.run("/bin/sh", ["-c", command])
    }

    try await git(["init", "-b", "main"])
    try await git(["config", "user.name", "验收"])
    try await git(["config", "user.email", "t@example.com"])
    try "let a = 1\n".write(to: repo.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

    // Not a repository never crashes a write.
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.stageCommand(directory: root.path, path: "a"))), .notARepository)

    // Stage → staged entry; unstage → untracked again.
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.stageCommand(directory: repo.path, path: "a.swift"))), .ok)
    var status = try RemoteGitCommand.parseStatus(try await run(RemoteGitCommand.statusCommand(directory: repo.path)))
    guard case .changes(_, _, let staged) = status else { fatalError("expected changes") }
    precondition(staged.first?.indexStatus == "A")
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.unstageCommand(directory: repo.path, path: "a.swift"))), .ok)
    status = try RemoteGitCommand.parseStatus(try await run(RemoteGitCommand.statusCommand(directory: repo.path)))
    guard case .changes(_, _, let unstaged) = status else { fatalError("expected changes") }
    precondition(unstaged.first?.untracked == true)

    // Commit with a message that would break naive quoting; log shows it whole.
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.stageCommand(directory: repo.path, path: "a.swift"))), .ok)
    let message = "初始提交 $(not-a-command) `nor this` 中文"
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.commitCommand(directory: repo.path, message: message))), .ok)
    let log = try RemoteGitCommand.parseLog(try await run(RemoteGitCommand.logCommand(directory: repo.path)))
    expectEqual(log?.count, 1)
    expectEqual(log?.first?.subject, message)

    // Committing with nothing staged fails with git's own message.
    guard case .failed(let failure) = try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.commitCommand(directory: repo.path, message: "空"))) else {
        fatalError("expected failure")
    }
    precondition(!failure.isEmpty)

    // Branch list + switch round-trip.
    try await git(["branch", "feature/x"])
    let branches = try RemoteGitCommand.parseBranches(try await run(RemoteGitCommand.branchesCommand(directory: repo.path)))
    expectEqual(branches?.current, "main")
    expectEqual(branches?.names, ["feature/x", "main"])
    expectEqual(try RemoteGitCommand.parseWrite(try await run(
        RemoteGitCommand.switchCommand(directory: repo.path, branch: "feature/x"))), .ok)
    expectEqual(try RemoteGitCommand.parseBranches(try await run(
        RemoteGitCommand.branchesCommand(directory: repo.path)))?.current, "feature/x")

    // git show shares the diff envelope.
    let hash = log?.first?.hash ?? ""
    precondition(!hash.isEmpty)
    guard case .text(let shown, _) = try RemoteGitCommand.parseDiff(try await run(
        RemoteGitCommand.showCommand(directory: repo.path, commit: hash))) else { fatalError("expected text diff") }
    precondition(shown.contains(message) && shown.contains("+let a = 1"))

    print("PASS: remote git write — quoting, stage/unstage/commit/switch, branches, log, show")
}
