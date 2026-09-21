import Foundation
import WorkbenchCore

/// Runs the real git scripts against a throwaway local repository, so quoting,
/// external-diff refusal, truncation and non-repository handling are checked
/// without touching any remote host or the user's own repositories.
func checkRemoteGitDiff() async throws {
    expectTrue(RemoteGitCommand.statusCommand(directory: "/x").contains("--porcelain=v1"))
    let arguments = RemoteGitCommand.sshArguments(destination: "dev-env",
                                                  command: RemoteGitCommand.statusCommand(directory: "/x"))
    expectTrue(arguments.contains("BatchMode=yes"))
    expectTrue(arguments.contains("StrictHostKeyChecking=yes"))
    expectEqual(arguments[arguments.count - 2], "dev-env")

    // Both operands must survive as single argv elements and must not be evaluated.
    let hostile = "/tmp/a b/$(printf SUBSTITUTED)/`printf EXECUTED`/-rf/中文"
    let command = RemoteGitCommand.diffCommand(directory: hostile, path: hostile, staged: false)
    // sh -c <script> <name> <directory> <path>: the two operands are $5 and $6.
    let echoed = try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(command); printf '%s\\0%s\\0' \"$5\" \"$6\""])
    expectEqual(String(decoding: echoed, as: UTF8.self), hostile + "\0" + hostile + "\0")
    expectTrue(command.contains("--no-ext-diff"))
    expectTrue(command.contains("--no-textconv"))
    expectTrue(command.contains("diff.external="))
    // A path operand must stay after `--`, never be read as a revision or option.
    expectTrue(command.contains("--"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("awb-remote-git-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("仓库 repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    func git(_ arguments: [String]) async throws {
        _ = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + arguments)
    }
    func status() async throws -> RemoteGitStatus {
        let data = try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.statusCommand(directory: repo.path)])
        return try RemoteGitCommand.parseStatus(data)
    }
    func diff(_ path: String, staged: Bool, limit: Int = RemoteGitCommand.diffLimit) async throws -> RemoteGitDiff {
        let script = RemoteGitCommand.diffCommand(directory: repo.path, path: path, staged: staged, limit: limit)
        return try RemoteGitCommand.parseDiff(try await ProcessRunner.run("/bin/sh", ["-c", script]), limit: limit)
    }

    // A plain directory is not a repository, and that is a state rather than an error.
    let plain = try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.statusCommand(directory: root.path)])
    expectEqual(try RemoteGitCommand.parseStatus(plain), .notARepository)
    expectEqual(try RemoteGitCommand.parseDiff(
        try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.diffCommand(
            directory: root.path, path: "x", staged: false)])), .notARepository)
    // A missing directory must not fall through to the caller's own working directory.
    let missing = try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.statusCommand(
        directory: root.appendingPathComponent("absent").path)])
    expectEqual(try RemoteGitCommand.parseStatus(missing), .notARepository)

    try await git(["init", "--quiet", "-b", "main"])
    try await git(["config", "user.email", "fixture@example.test"])
    try await git(["config", "user.name", "Fixture"])
    try Data("第一行\n第二行\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try Data("keep\n".utf8).write(to: repo.appendingPathComponent("stable.txt"))
    try await git(["add", "."])
    try await git(["commit", "--quiet", "-m", "fixture"])
    guard case .clean = try await status() else { fatalError("Expected a clean repository") }

    // Mixed states: staged edit, unstaged edit, untracked file and a rename.
    try Data("第一行\n第二行 修改\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try await git(["add", "说明.md"])
    try Data("第一行\n第二行 修改\n第三行 未暂存\n".utf8).write(to: repo.appendingPathComponent("说明.md"))
    try Data("新文件\n".utf8).write(to: repo.appendingPathComponent("未跟踪 file.txt"))
    try await git(["mv", "stable.txt", "renamed.txt"])

    guard case .changes(let repoRoot, let entries) = try await status() else { fatalError("Expected changes") }
    // git reports the resolved toplevel; macOS resolves /var to /private/var, and
    // Foundation normalizes it back, so both sides go through the same normalization.
    expectEqual(URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path,
                repo.resolvingSymlinksInPath().path)
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    guard let note = byPath["说明.md"] else { fatalError("Missing the edited file") }
    expectTrue(note.hasStaged)
    expectTrue(note.hasUnstaged)
    expectFalse(note.untracked)
    guard let untracked = byPath["未跟踪 file.txt"] else { fatalError("Missing the untracked file") }
    // An untracked file must never be presented as a tracked diff.
    expectTrue(untracked.untracked)
    expectEqual(untracked.label, "未跟踪")
    expectFalse(untracked.hasStaged)
    guard let renamed = byPath["renamed.txt"] else { fatalError("Missing the renamed file") }
    expectEqual(renamed.originalPath, "stable.txt")
    expectEqual(renamed.indexStatus, "R")

    guard case .text(let unstaged, false) = try await diff("说明.md", staged: false) else { fatalError("Expected unstaged text") }
    expectTrue(unstaged.contains("+第三行 未暂存"))
    expectFalse(unstaged.contains("+第二行 修改"))
    guard case .text(let staged, false) = try await diff("说明.md", staged: true) else { fatalError("Expected staged text") }
    expectTrue(staged.contains("+第二行 修改"))
    expectFalse(staged.contains("+第三行 未暂存"))
    expectEqual(try await diff("renamed.txt", staged: false), .empty)

    // A configured external diff command must not run.
    try await git(["config", "diff.external", "/bin/sh -c 'printf EXTERNAL_RAN'"])
    guard case .text(let guarded, _) = try await diff("说明.md", staged: false) else { fatalError("Expected text") }
    expectFalse(guarded.contains("EXTERNAL_RAN"))
    try await git(["config", "--unset", "diff.external"])

    let binary = repo.appendingPathComponent("blob.bin")
    try Data([0x00, 0x01, 0x02, 0xff]).write(to: binary)
    try await git(["add", "blob.bin"])
    expectEqual(try await diff("blob.bin", staged: true), .binary)

    let large = repo.appendingPathComponent("large.txt")
    try Data(String(repeating: "中文内容行\n", count: 4_000).utf8).write(to: large)
    try await git(["add", "large.txt"])
    guard case .text(let clipped, true) = try await diff("large.txt", staged: true, limit: 2_000)
    else { fatalError("Expected a truncated diff") }
    expectTrue(clipped.utf8.count <= 2_000)
    expectFalse(clipped.contains("\u{FFFD}"))

    print("PASS: remote git status states, staged/unstaged diffs, rename and untracked identity, external-diff refusal, binary and truncation")
}
