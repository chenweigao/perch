import AppKit
import Foundation

let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
let summaryFont = NSFont.systemFont(ofSize: 12)
let title = "Current workspace diff" as NSString
let summary = "2 files" as NSString
let result: [String: Any] = [
    "scope": "Supporting system-font metrics; screenshots remain the layout evidence",
    "title": title,
    "title_width": title.size(withAttributes: [.font: titleFont]).width,
    "summary": summary,
    "summary_width": summary.size(withAttributes: [.font: summaryFont]).width,
    "title_font_size": titleFont.pointSize,
    "summary_font_size": summaryFont.pointSize,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
