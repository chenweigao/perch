import Foundation

public struct ModelOption: Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let name: String
    public let capabilities: [String]
}
public struct ModelProviderGroup: Identifiable, Equatable {
    public let id: String
    public let models: [ModelOption]
}
public enum ModelCatalog {
    public static func options(_ items: [JSONValue]) -> [ModelOption] {
        items.compactMap { item in
            guard let id = item["model"].string, !id.isEmpty, let provider = item["provider"].string else { return nil }
            return ModelOption(id: id, provider: provider, name: item["display_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? String(id.split(separator: "/").last ?? Substring(id)), capabilities: item["capabilities"].array.compactMap(\.string))
        }
    }
    /// The native catalog reaches the same picker. Starting a session sends only the
    /// id, so two vendors sharing one id are one choice here — keeping both would
    /// give the list two rows with the same identity and the same effect.
    public static func options(_ models: [AgentModel]) -> [ModelOption] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard seen.insert(model.id).inserted else { return nil }
            return ModelOption(id: model.id, provider: model.provider, name: model.name, capabilities: [])
        }
    }
    public static func groups(_ options: [ModelOption], matching query: String = "") -> [ModelProviderGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = options.filter { query.isEmpty || "\($0.provider) \($0.name) \($0.id)".localizedCaseInsensitiveContains(query) }
        return Dictionary(grouping: filtered, by: \.provider).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ModelProviderGroup(id: $0.key, models: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }
}
