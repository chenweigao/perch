import Foundation
import WorkbenchCore

/// Exercises the real path/command/parse implementation, not a mirrored copy.
/// The remote script runs against a local /bin/sh fixture directory so quoting,
/// truncation and refusal paths are checked without any SSH access.
func checkRemoteFileViewer() async throws {
    let cwd = "/home/user/project"
    expectEqual(try RemoteFilePath.resolve("docs/notes.md", cwd: cwd), "/home/user/project/docs/notes.md")
    expectEqual(try RemoteFilePath.resolve("/etc/hosts", cwd: cwd), "/etc/hosts")
    expectEqual(try RemoteFilePath.resolve("  ../sibling/中文 文件.txt  ", cwd: cwd), "/home/user/sibling/中文 文件.txt")
    expectEqual(try RemoteFilePath.resolve("./a/./b/../c", cwd: cwd), "/home/user/project/a/c")
    // Never escape above root, and never resolve against the Mac's own filesystem.
    expectEqual(try RemoteFilePath.resolve("/../../etc", cwd: cwd), "/etc")
    expectEqual(try RemoteFilePath.resolve("~/logs", cwd: cwd), "~/logs")
    expectThrows(try RemoteFilePath.resolve("", cwd: cwd))
    expectThrows(try RemoteFilePath.resolve("relative", cwd: ""))
    expectEqual(RemoteFilePath.parent(of: "/a/b"), "/a")
    expectEqual(RemoteFilePath.parent(of: "/a"), "/")
    expectEqual(RemoteFilePath.parent(of: "/"), nil)
    expectEqual(RemoteFilePath.child("/", "x"), "/x")
    expectEqual(RemoteFilePath.child("/a", "x"), "/a/x")

    // The path must stay a single argv element and must never be executed.
    let hostile = "/tmp/a b/'quoted'/$(printf SUBSTITUTED)/`printf EXECUTED`/-rf/中文"
    let command = RemoteFileCommand.remoteCommand(path: hostile)
    let echoed = try await ProcessRunner.run("/bin/sh", ["-c", "set -- \(command); printf '%s\\0' \"$5\""])
    expectEqual(String(decoding: echoed, as: UTF8.self), hostile + "\0")
    expectFalse(command.contains("SUBSTITUTED\n"))

    let arguments = RemoteFileCommand.sshArguments(destination: "dev-env", controlPath: "/tmp/awb/ssh", path: "/etc/hosts")
    expectTrue(arguments.contains("BatchMode=yes"))
    expectTrue(arguments.contains("StrictHostKeyChecking=yes"))
    expectEqual(arguments.first, "-T")
    expectEqual(arguments[arguments.count - 2], "dev-env")
    expectFalse(arguments.contains("-t"))
    expectFalse(RemoteFileCommand.sshArguments(destination: "dev-env", controlPath: nil, path: "/x").contains("-S"))

    // Run the actual remote script locally against an isolated fixture tree.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("awb-remote-file-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("中文 目录")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("子目录"), withIntermediateDirectories: true)
    try Data("第一行\n第二行 with english\n".utf8).write(to: directory.appendingPathComponent("-leading-hyphen.txt"))
    try Data([0x00, 0x01, 0x02, 0xff]).write(to: directory.appendingPathComponent("binary.bin"))
    // A multi-byte character straddling the limit must not become U+FFFD.
    let large = String(repeating: "中文内容", count: 400)
    try Data(large.utf8).write(to: directory.appendingPathComponent("large.txt"))

    func read(_ path: String, limit: Int = RemoteFileCommand.readLimit) async throws -> RemoteFileContent {
        let script = RemoteFileCommand.remoteCommand(path: path, limit: limit)
        return try RemoteFileCommand.parse(try await ProcessRunner.run("/bin/sh", ["-c", script]), limit: limit)
    }

    guard case .directory(let entries) = try await read(directory.path) else { fatalError("Expected a directory") }
    expectEqual(entries.map(\.name), ["子目录", "-leading-hyphen.txt", "binary.bin", "large.txt"])
    expectTrue(entries[0].isDirectory)
    expectFalse(entries[1].isDirectory)

    guard case .text(let text, let truncated, _) = try await read(directory.appendingPathComponent("-leading-hyphen.txt").path)
    else { fatalError("Expected text") }
    expectEqual(text, "第一行\n第二行 with english\n")
    expectFalse(truncated)

    guard case .binary = try await read(directory.appendingPathComponent("binary.bin").path) else { fatalError("Expected binary") }
    expectEqual(try await read(root.appendingPathComponent("missing").path), .missing)

    guard case .text(let clipped, let wasTruncated, let size) = try await read(directory.appendingPathComponent("large.txt").path, limit: 1_000)
    else { fatalError("Expected truncated text") }
    expectTrue(wasTruncated)
    expectEqual(size, large.utf8.count)
    expectFalse(clipped.contains("\u{FFFD}"))
    expectTrue(clipped.utf8.count <= 1_000)
    expectTrue(large.hasPrefix(clipped))

    let unreadable = directory.appendingPathComponent("denied.txt")
    try Data("secret".utf8).write(to: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    expectEqual(try await read(unreadable.path), .denied)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)

    // Replay a conversation citing a filename while its cwd is the parent of the repo.
    let source = root.appendingPathComponent("perch/Sources/AgentWorkbench")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let filename = "WorkbenchHeaderActions.swift"
    let sourceFile = source.appendingPathComponent(filename)
    try Data("line 54\n".utf8).write(to: sourceFile)
    func reference(_ path: String, roots: [String] = []) async throws -> RemoteFileContent {
        let command = try RemoteFileCommand.referenceCommand(path: path, cwd: root.path, roots: roots)
        return try RemoteFileCommand.parse(try await ProcessRunner.run("/bin/sh", ["-c", command]))
    }
    expectEqual(try await reference(filename), .matches([sourceFile.path]))
    expectEqual(try await read(sourceFile.path), .text("line 54\n", truncated: false, size: 8))
    expectEqual(try await reference("absent.swift"), .missing)
    // Explicit paths must not silently select another file with the same name.
    expectEqual(try await reference(root.appendingPathComponent(filename).path), .missing)
    expectEqual(try await reference("missing/" + filename), .missing)

    let duplicate = root.appendingPathComponent("_worktrees/perch/Sources/AgentWorkbench")
    try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
    let duplicateFile = duplicate.appendingPathComponent(filename)
    try Data("another worktree".utf8).write(to: duplicateFile)
    expectEqual(try await reference(filename), .matches([sourceFile.path, duplicateFile.path].sorted()))
    // A file at the exact cwd-relative path wins even when there are nested matches.
    let direct = root.appendingPathComponent(filename)
    try Data("direct".utf8).write(to: direct)
    expectEqual(try await reference(filename), .text("direct", truncated: false, size: 6))

    let literalName = "file[1] $(printf INJECTED).swift"
    let literalFile = source.appendingPathComponent(literalName)
    try Data("literal".utf8).write(to: literalFile)
    try Data("wrong glob match".utf8).write(to: source.appendingPathComponent("file1 $(printf INJECTED).swift"))
    expectEqual(try await reference(literalName), .matches([literalFile.path]))

    // Multi-root resolution: a reference citing a path below a worktree resolves
    // there even though the session directory has no such path, and when both
    // checkouts contain the relative path the earlier root wins — the agent's
    // recent tool calls order the roots.
    let main = root.appendingPathComponent("perch").path
    let worktree = root.appendingPathComponent("_worktrees/perch").path
    let relative = "Sources/AgentWorkbench/\(filename)"
    expectEqual(try await reference(relative, roots: [worktree, main]),
                .text("another worktree", truncated: false, size: 16))
    expectEqual(try await reference(relative, roots: [main, worktree]),
                .text("line 54\n", truncated: false, size: 8))
    // The session directory stays appended as a fallback but never overrides a hint.
    expectEqual(try await reference(relative, roots: [worktree]),
                .text("another worktree", truncated: false, size: 16))

    // The header echoes the path the remote actually read.
    let echo = try RemoteFileCommand.referenceCommand(path: relative, cwd: root.path, roots: [worktree])
    let echoedData = try await ProcessRunner.run("/bin/sh", ["-c", echo])
    expectEqual(RemoteFileCommand.resolvedPath(in: echoedData), duplicateFile.path)

    // A bare filename is searched across every root, including one outside the
    // session directory; a root that vanished mid-session is skipped, and
    // overlapping roots never list the same file twice.
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("awb-remote-outside-\(UUID())")
    defer { try? FileManager.default.removeItem(at: outside) }
    let onlyOutside = "OnlyOutside-\(UUID().uuidString.prefix(8)).swift"
    try FileManager.default.createDirectory(at: outside.appendingPathComponent("deep"), withIntermediateDirectories: true)
    let outsideFile = outside.appendingPathComponent("deep/\(onlyOutside)")
    try Data("outside\n".utf8).write(to: outsideFile)
    expectEqual(try await reference(onlyOutside, roots: [outside.path]), .matches([outsideFile.path]))
    expectEqual(try await reference(onlyOutside, roots: [root.appendingPathComponent("gone").path, outside.path]),
                .matches([outsideFile.path]))
    // Overlapping roots (a directory and its parent) list the same file once.
    let dedupeName = "Dedupe-\(UUID().uuidString.prefix(8)).swift"
    let dedupeFile = source.appendingPathComponent(dedupeName)
    try Data("dedupe\n".utf8).write(to: dedupeFile)
    expectEqual(try await reference(dedupeName, roots: [root.appendingPathComponent("perch/Sources").path, main]),
                .matches([dedupeFile.path]))

    print("PASS: remote path resolution, conversation filename lookup and ambiguity, multi-root ordering, argument isolation, directory listing, truncation, binary/denied/missing states")
}
