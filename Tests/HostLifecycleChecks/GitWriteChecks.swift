import AppKit
import WorkbenchCore

@MainActor func checkGitWriteLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("perch-git-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ directory: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", directory.path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); precondition(p.terminationStatus == 0)
    }
    let a = root.appendingPathComponent("alpha"), b = root.appendingPathComponent("beta")
    for repo in [a, b] {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, ["init", "-b", repo.lastPathComponent])
        try git(repo, ["config", "user.name", "Fixture"])
        try git(repo, ["config", "user.email", "t@example.com"])
        try git(repo, ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", repo.lastPathComponent])
        try git(repo, ["config", "commit.gpgsign", "false"])
    }
    let browser = RemoteFileBrowser()
    let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "Local fixture", destination: "")
    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        preconditionFailure("Timed out waiting for Git browser state: \(browser.error ?? browser.gitWriteError ?? "none")")
    }
    browser.configure(host: host, cwd: a.path); browser.loadGitStatus()
    try await waitUntil { browser.gitLog?.first?.subject == "alpha" }
    precondition(browser.gitBranches?.current == "alpha")
    browser.gitInput = b.path; browser.submitGitDirectory()
    precondition(browser.gitBranches == nil && browser.gitLog == nil)
    try await waitUntil { browser.gitLog?.first?.subject == "beta" }
    precondition(browser.gitBranches?.current == "beta")
    browser.gitInput = a.path; browser.submitGitDirectory()
    try await waitUntil { browser.gitBranches?.current == "alpha" && browser.gitLog != nil }
    try "new content".write(to: a.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try git(a, ["add", "file.txt"])
    let hook = a.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    browser.gitCommitMessage = "survives navigation"; browser.commitGit()
    precondition(browser.gitWriting)
    browser.cancel()
    browser.gitInput = b.path; browser.submitGitDirectory()
    precondition(!browser.gitWriting, "Unrelated repositories must not inherit the busy state")
    browser.gitInput = a.path; browser.submitGitDirectory()
    precondition(browser.gitWriting, "Returning to the same repository must retain its pending write")
    try await waitUntil { !browser.gitWriting && browser.gitLog?.first?.subject == "survives navigation" }
    precondition(browser.gitWriteError == nil)
    browser.cancel()
    print("PASS: Git repository metadata refresh, write completion after page cancellation/navigation, repository-scoped busy state")
}
