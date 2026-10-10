import SwiftUI
import WorkbenchCore

/// Frequently used prompts, app-wide and UserDefaults-persisted. Newest first.
@MainActor @Observable
final class ComposerTemplatesStore {
    static let shared = ComposerTemplatesStore()
    private(set) var templates: [String] = []
    private let defaultsKey = "perch.composerTemplates"
    private let limit = 20

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        templates = decoded
    }

    func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        templates.removeAll { $0 == trimmed }
        templates.insert(trimmed, at: 0)
        if templates.count > limit { templates = Array(templates.prefix(limit)) }
        persist()
    }

    func remove(_ template: String) {
        templates.removeAll { $0 == template }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Composer toolbar menu: pick a template to append to the draft, save the
/// current draft as a template, or delete stale ones.
struct ComposerTemplatesMenu: View {
    let draft: String
    /// Insert into the draft; an empty draft becomes the template, otherwise
    /// the template appends after a blank line.
    let insert: (String) -> Void
    private var store: ComposerTemplatesStore { .shared }

    var body: some View {
        Menu {
            ForEach(store.templates, id: \.self) { template in
                Button(template.components(separatedBy: .newlines).first.map { String($0.prefix(60)) } ?? "模板") {
                    insert(template)
                }.help(template)
            }
            if !store.templates.isEmpty { Divider() }
            Button("保存当前草稿为模板") { store.save(draft) }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !store.templates.isEmpty {
                Menu("删除模板") {
                    ForEach(store.templates, id: \.self) { template in
                        Button(template.components(separatedBy: .newlines).first.map { String($0.prefix(60)) } ?? "模板") {
                            store.remove(template)
                        }.help(template)
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("常用提示模板").accessibilityLabel("常用提示模板")
    }
}
