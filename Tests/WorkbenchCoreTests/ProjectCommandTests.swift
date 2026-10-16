import Foundation
import WorkbenchCore

func checkProjectCommands() throws {
    // The script scans the Claude Code and opencode conventions under the session cwd.
    let script = ProjectCommandCatalog.script(cwd: "/home/user/proj ect")
    for directory in ProjectCommandCatalog.directories {
        precondition(script.contains(directory), "script covers \(directory)")
    }
    precondition(!script.contains("/home/user/proj ect/*.md") || script.contains("'"),
                 "paths with spaces are quoted")

    func record(_ name: String, _ body: String) -> String {
        ">>\(name)\n" + Data(body.utf8).base64EncodedString() + "\n"
    }
    let frontmatter = """
    ---
    description: 评审当前改动
    ---
    请评审 $ARGUMENTS 的改动。

    保持中文回答。
    """
    let plain = "修复这个 bug，先写复现测试。"
    let empty = "\n\n"
    let output = record("review", frontmatter)
        + record("fix-bug", plain)
        + record("review", "第二次出现，去重")
        + record("empty", empty)
        + ">>broken\nnot-base64!!!\n"
        + "noise line without record\n"
    let commands = ProjectCommandCatalog.parse(Data(output.utf8))
    precondition(commands.map(\.name) == ["fix-bug", "review"], "parsed, deduped, sorted: \(commands.map(\.name))")
    let review = commands.first { $0.name == "review" }!
    precondition(review.source == "project" && review.description == "评审当前改动")
    precondition(review.prompt == "请评审 $ARGUMENTS 的改动。\n\n保持中文回答。", "frontmatter leaves the prompt")
    let fix = commands.first { $0.name == "fix-bug" }!
    precondition(fix.description == "修复这个 bug，先写复现测试。", "first content line describes")
    precondition(fix.prompt == plain)

    // Expansion follows the $ARGUMENTS convention; without it arguments append.
    precondition(ProjectCommandCatalog.expand(review, arguments: "feat/x") ==
                 "请评审 feat/x 的改动。\n\n保持中文回答。")
    precondition(ProjectCommandCatalog.expand(fix, arguments: "紧急") == plain + "\n\n紧急")
    precondition(ProjectCommandCatalog.expand(fix, arguments: "") == plain)
    print("PASS: project slash commands — script, parse, frontmatter, dedup, expansion")
}
