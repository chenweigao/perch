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
    do { _ = try ProjectFileCatalog.parse(Data("kind=notrepo\n".utf8)); fatalError("Non-repository must report an error") }
    catch { expectTrue(error.localizedDescription.contains("Git")) }
    do {
        _ = try ProjectFileCatalog.parse(Data("/project\0".utf8) + Data(repeating: 65, count: ProjectFileCatalog.limit + 1))
        fatalError("Oversized lists must not produce partial paths")
    } catch { expectTrue(error.localizedDescription.contains("文件")) }
    print("PASS: project file references preserve Unicode selections and draft text; Git catalog excludes ignored paths and bounds output")
}
