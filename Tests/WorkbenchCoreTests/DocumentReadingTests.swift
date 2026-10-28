import Foundation
import WorkbenchCore

func checkDocumentReading() throws {
    let document = ReadingDocument("# 中文 标题\r\n\r\nRead **bold** and [next](sub/next%20page.md#second).\r\n\r\n## Details\r\n\r\n![chart](images/chart.png)\r\n\r\n## Details\r\n\r\n```markdown\n# Not a heading\n```\n\n| A | B |\n| --- | --- |\n| needle | yes |")
    expectEqual(document.outline.map(\.anchor), ["中文-标题", "details", "details-1"])
    expectEqual(document.sections.flatMap(\.images).map(\.target), ["images/chart.png"])
    expectEqual(document.matchingSections("BOLD").count, 1)
    expectEqual(document.matchingSections("needle").count, 1)
    expectTrue(document.matchingSections("absent").isEmpty)
    let url = DocumentLink.url("sub/next%20page.md#second")!
    expectEqual(DocumentLink.target(url), "sub/next%20page.md#second")
    expectEqual(DocumentLink.resolve(DocumentLink.target(url)!, relativeTo: "/project/report.md"), .file("/project/sub/next page.md", anchor: "second"))
    expectEqual(DocumentLink.resolve("../notes.md#中文-标题", relativeTo: "/project/docs/report.md"), .file("/project/notes.md", anchor: "中文-标题"))
    expectEqual(DocumentLink.resolve("#details-1", relativeTo: "/project/report.md"), .file("/project/report.md", anchor: "details-1"))
    for target in ["javascript:alert(1)", "file:///etc/passwd", "//other-host/notes.md", "data:text/html,test", "notes.md?exec=1"] {
        expectEqual(DocumentLink.resolve(target, relativeTo: "/project/report.md"), .blocked)
    }
    if case .web(let url) = DocumentLink.resolve("https://example.com/a#b", relativeTo: "/project/report.md") {
        expectEqual(url.host, "example.com")
    } else { fatalError("Expected explicit external link") }
    if case .paragraph(let runs) = ReplyDocument.parse("[section](#details)", documentLinks: true).first {
        expectEqual(runs.first?.link?.scheme, "perch-document")
    } else { fatalError("Expected native document link") }
    if case .paragraph(let runs) = ReplyDocument.parse("[section](#details)").first {
        expectFalse(runs.contains { $0.link?.scheme == "perch-document" })
    }
    let referenced = ReadingDocument("[plan][doc]\n\n[doc]: next.md#summary")
    if case .paragraph(let runs) = referenced.sections.first?.blocks.first {
        expectEqual(runs.first?.link.flatMap(DocumentLink.target), "next.md#summary")
    } else { fatalError("Expected reference-style document link") }
    var workspace = LocalWorkspace()
    let project = SidebarProjectLocation(hostID: UUID(), directory: "/project", hostName: "Fixture")
    var entry = ProjectDocument(project: project, path: "/project/report.md", title: "Report", source: nil, modifiedAt: 123)
    entry.pinned = true; workspace.documents = [entry]
    expectEqual(try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace)).documents, [entry])
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
    legacy.removeValue(forKey: "documents")
    expectTrue(try JSONDecoder().decode(LocalWorkspace.self, from: JSONSerialization.data(withJSONObject: legacy)).documents.isEmpty)
    expectEqual(RemoteFileCommand.modifiedAt(in: Data("kind=file\nmtime=123\nsize=4\n--\ntext".utf8)), 123)
    expectEqual(RemoteFileCommand.modifiedAt(in: Data("kind=file\nsize=4\n--\ntext".utf8)), nil)
    print("Document reading contracts passed")
}
