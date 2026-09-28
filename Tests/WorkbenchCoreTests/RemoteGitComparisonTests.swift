import Foundation
import WorkbenchCore

func checkRemoteGitComparison() async throws {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent("perch-branch-review-\(UUID())")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    func git(_ args: [String]) async throws -> Data {
        try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args)
    }
    func write(_ path: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    func compare(_ base: String) async throws -> RemoteGitComparison {
        try RemoteGitCommand.parseComparison(await ProcessRunner.run("/bin/sh", ["-c",
            RemoteGitCommand.comparisonCommand(directory: repo.path, base: base)]))
    }
    func diff(_ comparison: RemoteGitComparison, _ path: String, limit: Int = RemoteGitCommand.diffLimit) async throws -> RemoteGitDiff {
        let entry = comparison.entries.first { $0.path == path }!
        return try RemoteGitCommand.parseDiff(await ProcessRunner.run("/bin/sh", ["-c",
            RemoteGitCommand.comparisonDiffCommand(comparison: comparison, entry: entry, limit: limit)]), limit: limit)
    }
    _ = try await git(["init", "-q", "-b", "main"])
    _ = try await git(["config", "user.name", "Fixture"])
    _ = try await git(["config", "user.email", "fixture@example.test"])
    _ = try await git(["config", "core.hooksPath", "/dev/null"])
    try write("original.txt", "keep the original contents\n")
    try write("deleted.txt", "old contents\n")
    try write("说明.md", "base\n")
    _ = try await git(["add", "."])
    _ = try await git(["commit", "-qm", "base"])
    _ = try await git(["branch", "feature"])
    // Target-only work after divergence must not appear in the feature review.
    try write("target-only.txt", "main only\n")
    _ = try await git(["add", "."])
    _ = try await git(["commit", "-qm", "target advanced"])
    _ = try await git(["switch", "-q", "feature"])
    _ = try await git(["mv", "original.txt", "renamed 中文.txt"])
    _ = try await git(["rm", "deleted.txt"])
    try write("说明.md", "committed 中文\n")
    try write(":(glob)*.txt", "literal path only\n")
    try Data([0, 255, 1]).write(to: repo.appendingPathComponent("binary.bin"))
    _ = try await git(["add", "."])
    _ = try await git(["commit", "-qm", "feature changes"])
    try write("说明.md", "dirty content must stay out\n")
    try write("untracked.txt", "not committed\n")
    let originalStatus = try await git(["status", "--porcelain=v1", "-z"])
    let originalHead = try await git(["rev-parse", "HEAD"])
    let comparison = try await compare("main")
    expectEqual(comparison.baseRef, "main")
    expectFalse(comparison.baseCommit == comparison.mergeBase)
    expectEqual(Set(comparison.entries.map(\.path)), Set(["renamed 中文.txt", "deleted.txt", "说明.md", ":(glob)*.txt", "binary.bin"]))
    expectEqual(comparison.entries.first { $0.path == "renamed 中文.txt" }?.originalPath, "original.txt")
    guard case .text(let text, false) = try await diff(comparison, "说明.md") else { fatalError("Missing committed diff") }
    expectTrue(text.contains("+committed 中文"))
    expectFalse(text.contains("dirty content"))
    guard case .text(let renamed, false) = try await diff(comparison, "renamed 中文.txt") else { fatalError("Missing rename") }
    expectTrue(renamed.contains("rename from original.txt"))
    guard case .text(let literal, false) = try await diff(comparison, ":(glob)*.txt") else { fatalError("Missing literal path") }
    expectTrue(literal.contains("+literal path only"))
    expectFalse(literal.contains("deleted.txt"))
    expectEqual(try await diff(comparison, "binary.bin"), .binary)
    guard case .text(let deleted, false) = try await diff(comparison, "deleted.txt") else { fatalError("Missing deletion") }
    expectTrue(deleted.contains("-old contents"))
    expectEqual(try await git(["status", "--porcelain=v1", "-z"]), originalStatus)
    expectEqual(try await git(["rev-parse", "HEAD"]), originalHead)
    expectTrue(try await compare("HEAD").entries.isEmpty)

    // Configured external diff helpers must never run during read-only review.
    _ = try await git(["config", "diff.external", "/bin/sh -c 'printf EXTERNAL_RAN'"])
    expectEqual(try await diff(comparison, "说明.md"), .text(text, truncated: false))
    _ = try await git(["config", "--unset", "diff.external"])
    guard case .text(_, true) = try await diff(comparison, "说明.md", limit: 40) else { fatalError("Missing truncation") }
    for base in ["absent-branch", "--output=/tmp/perch-should-not-write", "$(printf unexpected)"] {
        do { _ = try await compare(base); fatalError("Expected invalid base") }
        catch { expectTrue(error.localizedDescription.contains("目标分支")) }
    }
    let refs = String(decoding: try await ProcessRunner.run("/bin/sh", ["-c", RemoteGitCommand.reviewRefsCommand(directory: repo.path)]), as: UTF8.self)
    expectTrue(refs.contains("refs/heads/main"))
    expectTrue(refs.contains("refs/heads/feature"))
    var progress = GitReviewProgress()
    progress.reconcile(comparison.versions)
    progress.toggleReviewed("说明.md")
    progress.toggleReviewed("deleted.txt")
    progress.lastPath = "说明.md"
    progress.offsets["说明.md"] = 120
    let persisted = try JSONDecoder().decode(GitReviewProgress.self, from: JSONEncoder().encode(progress))
    expectEqual(persisted, progress)
    progress.reconcile(comparison.versions)
    expectTrue(progress.isReviewed("说明.md"))
    expectEqual(progress.offsets["说明.md"], 120)
    // Both refs can move while the reader keeps reviewing the original snapshot.
    _ = try await git(["add", "说明.md"])
    _ = try await git(["commit", "-qm", "later feature change"])
    let refreshed = try await compare(comparison.baseCommit)
    progress.reconcile(refreshed.versions)
    expectFalse(progress.isReviewed("说明.md"))
    expectTrue(progress.changed.contains("说明.md"))
    expectEqual(progress.offsets["说明.md"], nil)
    expectTrue(progress.isReviewed("deleted.txt"))
    expectEqual(progress.lastPath, "说明.md")
    progress.toggleReviewed("说明.md")
    expectFalse(progress.changed.contains("说明.md"))
    _ = try await git(["branch", "-f", "main", "HEAD"])
    progress.reconcile(try await compare("main").versions)
    expectTrue(progress.reviewed.isEmpty)
    expectEqual(progress.lastPath, nil)
    expectEqual(try await diff(comparison, "说明.md"), .text(text, truncated: false))
    expectTrue(try await compare("main").entries.isEmpty)
    let unrelated = String(decoding: try await git(["commit-tree", "HEAD^{tree}", "-m", "unrelated root"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    do { _ = try await compare(unrelated); fatalError("Expected no common ancestor") }
    catch { expectTrue(error.localizedDescription.contains("共同祖先")) }
    _ = try await git(["symbolic-ref", "HEAD", "refs/heads/unborn"])
    do { _ = try await compare(comparison.headCommit); fatalError("Expected unborn HEAD") }
    catch { expectTrue(error.localizedDescription.contains("还没有提交")) }
    print("PASS: committed branch review uses merge-base and pinned commits; preserves worktree, renames, deletions, binary, literal paths and bounded diffs")
}
