import Foundation
import WorkbenchCore

func checkProjectFileReferences() async throws {
    let text = "中文 before @Sour after"
    let caret = ("中文 before @Sour" as NSString).length
    let query = ProjectFileReference.query(in: text, selection: NSRange(location: caret, length: 0))!
    expectEqual(query.filter, "Sour")
    let path = "/tmp/project/空 格 \"file\".swift"
    let token = ProjectFileReference.token(path: path)
    let replaced = (text as NSString).replacingCharacters(in: query.range, with: token)
    expectTrue(replaced.hasPrefix("中文 before "))
    expectTrue(replaced.hasSuffix(" after"))
    let refs = ProjectFileReference.references(in: replaced)
    expectEqual(refs.map(\.path), [path])
    expectEqual((replaced as NSString).replacingCharacters(in: refs[0].range, with: ""), "中文 before  after")
    expectTrue(ProjectFileReference.query(in: "name@example.test", selection: NSRange(location: 17, length: 0)) == nil)
    expectTrue(ProjectFileReference.query(in: token, selection: NSRange(location: (token as NSString).length, length: 0)) == nil)
    expectTrue(ProjectFileReference.query(in: "@file", selection: NSRange(location: 1, length: 2)) == nil)

    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("perch-files-\(UUID())")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    _ = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "init", "-q"])
    let empty = try ProjectFileCatalog.parse(await ProcessRunner.run("/bin/sh", ["-c", ProjectFileCatalog.command(directory: repo.path)]))
    expectTrue(empty.paths.isEmpty)
    for (name, content) in [(".gitignore", "ignored.txt\n"), ("tracked.swift", "tracked"), ("空 格.swift", "new"), ("ignored.txt", "ignored")] {
        try content.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    _ = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "add", "tracked.swift"])
    let catalog = try ProjectFileCatalog.parse(await ProcessRunner.run("/bin/sh", ["-c", ProjectFileCatalog.command(directory: repo.path)]))
    expectEqual(URL(fileURLWithPath: catalog.root).resolvingSymlinksInPath().path, repo.resolvingSymlinksInPath().path)
    expectTrue(catalog.paths.contains("tracked.swift"))
    expectTrue(catalog.paths.contains("空 格.swift"))
    expectFalse(catalog.paths.contains("ignored.txt"))
    expectEqual(catalog.matches("TRACKED"), ["tracked.swift"])
    expectEqual(catalog.matches("空"), ["空 格.swift"])

    // A session can start below the repository root. Both tracked and new files
    // in sibling directories must remain available, with root-relative paths.
    for directory in ["Sources/Nested", "Sibling"] {
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for name in ["Sources/Nested/local.swift", "Sibling/tracked.swift", "Sibling/new.swift", "Sibling/ignored.txt"] {
        try "fixture".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    _ = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "add", "Sibling/tracked.swift"])
    let nested = try ProjectFileCatalog.parse(await ProcessRunner.run("/bin/sh", ["-c",
        ProjectFileCatalog.command(directory: repo.appendingPathComponent("Sources/Nested").path)]))
    expectTrue(nested.paths.contains("tracked.swift"))
    expectTrue(nested.paths.contains("空 格.swift"))
    expectTrue(nested.paths.contains("Sibling/tracked.swift"))
    expectTrue(nested.paths.contains("Sibling/new.swift"))
    expectTrue(nested.paths.contains("Sources/Nested/local.swift"))
    expectFalse(nested.paths.contains("Sibling/ignored.txt"))

    // Populate a large index without creating thousands of working-tree files.
    // The command must retain only limit + 1 bytes and still exit successfully,
    // leaving parse to report the useful size-limit error rather than SIGPIPE.
    let blob = String(decoding: try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "hash-object", "-w", "--stdin"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let indexInput = repo.appendingPathComponent(".git/catalog-index-input")
    let records = (0..<6000).map { "100644 \(blob)\tbulk/\($0)-\(String(repeating: "a", count: 200))\n" }.joined()
    try records.write(to: indexInput, atomically: true, encoding: .utf8)
    _ = try await ProcessRunner.run("/bin/sh", ["-c", "git -C \(SSHCommand.quote(repo.path)) update-index --index-info < \(SSHCommand.quote(indexInput.path))"])
    let large = try await ProcessRunner.run("/bin/sh", ["-c", ProjectFileCatalog.command(directory: repo.path)])
    expectEqual(large.count - large.firstIndex(of: 0)! - 1, ProjectFileCatalog.limit + 1)
    do { _ = try ProjectFileCatalog.parse(large); fatalError("Large Git catalogs must report the size limit") }
    catch { expectTrue(error.localizedDescription.contains("文件")) }

    // rev-parse still succeeds with a broken index; ls-files must fail through
    // the output limiter instead of being accepted as an empty catalog.
    try Data("broken index".utf8).write(to: repo.appendingPathComponent(".git/index"))
    do {
        _ = try await ProcessRunner.run("/bin/sh", ["-c", ProjectFileCatalog.command(directory: repo.path)])
        fatalError("Git index errors must propagate through the catalog command")
    } catch { expectTrue(error.localizedDescription.contains("index")) }

    // Ranking happens before the result limit, so folder-name hits cannot hide
    // the exact file or filename prefixes. Equal ranks retain catalog order.
    let rankingPaths = (0..<35).map { "A/File.swift/child-\($0).txt" }
        + ["Z/File.swift", "Y/File.swift.backup", "Z/File.swift.backup", "Z/空 格.swift"]
    let ranked = try ProjectFileCatalog.parse(Data(("/project\0" + rankingPaths.joined(separator: "\0") + "\0").utf8))
    expectEqual(Array(ranked.matches("FILE.SWIFT").prefix(3)), ["Z/File.swift", "Y/File.swift.backup", "Z/File.swift.backup"])
    expectEqual(ranked.matches("FILE.SWIFT").count, 30)
    expectEqual(ranked.matches("空"), ["Z/空 格.swift"])
    expectEqual(ranked.matches(""), Array(ranked.paths.prefix(30)))
    do { _ = try ProjectFileCatalog.parse(Data("kind=notrepo\n".utf8)); fatalError("Non-repository must report an error") }
    catch { expectTrue(error.localizedDescription.contains("Git")) }
    do {
        _ = try ProjectFileCatalog.parse(Data("/project\0".utf8) + Data(repeating: 65, count: ProjectFileCatalog.limit + 1))
        fatalError("Oversized lists must not produce partial paths")
    } catch { expectTrue(error.localizedDescription.contains("文件")) }
    print("PASS: project file references preserve Unicode drafts; catalog searches the whole repository, prioritizes filenames, caps output and propagates Git errors")
}
