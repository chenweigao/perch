import Foundation
import WorkbenchCore

func checkReviewContext() {
    let source = "first\n中文 👋 text\nlast\n"
    let selected = (source as NSString).range(of: "👋")
    let file = ReviewContext(path: "/project/代码.swift", text: source, selection: selected)
    precondition(file.lines == 2...2 && file.excerpt == "中文 👋 text")
    let rendered = "1 │ first\n2 │ 中文 👋 text\n3 │ last\n4 │ "
    let mapped = ReviewContext.sourceSelection(in: source, rendered: rendered, selection: (rendered as NSString).range(of: "👋"))
    precondition(ReviewContext(path: file.path, text: source, selection: mapped).lines == 2...2)
    let diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -10,2 +10,2 @@\n-old\n+new\n same\n@@ -30 +31 @@\n-gone\n+added\n"
    let removed = ReviewContext(path: "/project/a", text: diff, selection: (diff as NSString).range(of: "-gone"), diff: true, scope: "unstaged")
    precondition(removed.lines == nil && removed.oldLines == 30...30 && removed.excerpt == "-gone")
    let added = ReviewContext(path: "/project/a", text: diff, selection: (diff as NSString).range(of: "+added"), diff: true)
    precondition(added.lines == 31...31 && added.oldLines == nil)
    let header = ReviewContext(path: "/project/a", text: diff, selection: (diff as NSString).range(of: "+++ b/a"), diff: true)
    precondition(header.lines == nil && header.oldLines == nil)
    precondition(file.fingerprint != ReviewContext(path: file.path, text: source + "changed", selection: selected).fingerprint)
    precondition(file.prompt(feedback: "Please fix this").hasSuffix("\n\nPlease fix this"))
    precondition(file.prompt().contains("Snapshot SHA-256:"))
    print("PASS: file references preserve Unicode line selection; diff feedback distinguishes old/new lines and exact snapshot")
}
