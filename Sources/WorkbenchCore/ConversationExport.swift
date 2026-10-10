import Foundation

/// Renders loaded conversation messages as a portable Markdown or JSON document.
/// Export is a faithful local copy: visible text, thoughts, and tool calls,
/// never re-fetched or re-phrased content.
public enum ConversationExport {
    public static func markdown(_ messages: [KimiMessage]) -> String {
        var blocks: [String] = []
        for message in messages {
            if message.isUserPrompt {
                let text = visibleText(message.content)
                if !text.isEmpty { blocks.append("## 用户\n\n" + text) }
                blocks += attachmentLines(message.content)
                continue
            }
            if message.isCompactionSummary {
                blocks.append("---\n\n**上下文已压缩**\n\n" + (CompactionSummaryDisplay.humanText(message.content.compactMap(\.text).joined())))
                continue
            }
            for part in message.content {
                switch part.type {
                case "text":
                    if part.isRuntimeContext { continue }
                    let text = part.skillContextSplit?.prefix ?? part.text ?? ""
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    blocks.append("## 助手\n\n" + text)
                case "thinking":
                    guard let thinking = part.thinking, !thinking.isEmpty else { continue }
                    blocks.append("<details><summary>思考</summary>\n\n" + thinking + "\n\n</details>")
                case "tool_use":
                    var block = "### 工具调用：`\(part.toolName ?? part.name ?? "tool")`"
                    if let input = part.input?.display, !input.isEmpty { block += "\n\n```\n" + input + "\n```" }
                    blocks.append(block)
                case "tool_result":
                    var block = "### 工具结果"
                    if part.isError == true { block += "（错误）" }
                    if let output = part.output?.display ?? part.text, !output.isEmpty { block += "\n\n```\n" + output + "\n```" }
                    blocks.append(block)
                case "image", "file", "video":
                    blocks.append("> 附件：\(part.name ?? part.fileId ?? part.type ?? "file")")
                default: continue
                }
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func json(_ messages: [KimiMessage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.array(messages.map(jsonValue(_:))))
    }

    private static func jsonValue(_ message: KimiMessage) -> JSONValue {
        .object([
            "id": .string(message.id),
            "role": .string(message.role),
            "created_at": .string(message.createdAt),
            "content": .array(message.content.map { part in
                var object: [String: JSONValue] = ["type": .string(part.type)]
                if let text = part.text { object["text"] = .string(text) }
                if let thinking = part.thinking { object["thinking"] = .string(thinking) }
                if let toolCallId = part.toolCallId { object["tool_call_id"] = .string(toolCallId) }
                if let toolName = part.toolName { object["tool_name"] = .string(toolName) }
                if let name = part.name { object["name"] = .string(name) }
                if let input = part.input { object["input"] = input }
                if let output = part.output { object["output"] = output }
                if let isError = part.isError { object["is_error"] = .bool(isError) }
                if let fileId = part.fileId { object["file_id"] = .string(fileId) }
                return .object(object)
            })
        ])
    }

    private static func visibleText(_ parts: [KimiPart]) -> String {
        parts.filter { $0.type == "text" }
            .compactMap { $0.isRuntimeContext ? nil : ($0.skillContextSplit?.prefix ?? $0.text) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    private static func attachmentLines(_ parts: [KimiPart]) -> [String] {
        parts.filter { ["image", "file", "video"].contains($0.type) }
            .map { "> 附件：\($0.name ?? $0.fileId ?? $0.type ?? "file")" }
    }
}
