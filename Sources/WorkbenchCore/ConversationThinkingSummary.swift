import Foundation

/// Only provider-declared public summaries qualify for the live preview.
/// Raw reasoning is never sliced or promoted into a supposed summary.
public enum ConversationThinkingSummary {
    public static func latest(in messages: [KimiMessage]) -> String? {
        guard let part = messages.reversed().lazy.flatMap({ $0.content.reversed() }).first(where: { $0.type == "thinking" }),
              part.source?["kind"].string == "activity_summary" else { return nil }
        return clean(part.source?["summaryParts"].array.compactMap(\.string) ?? [])
    }

    public static func current(_ narrative: ActivityNarrative?) -> String? {
        guard let narrative, narrative.source == .provider else { return nil }
        return clean([narrative.headline, narrative.detail].compactMap { $0 })
    }

    private static func clean(_ parts: [String]) -> String? {
        let text = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
