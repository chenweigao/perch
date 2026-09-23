import SwiftUI
import WorkbenchCore

struct RenameSessionSheet: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    @State private var title = ""
    @State private var suggestion: String?
    @State private var suggesting = false
    @State private var suggestionTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名会话").font(.title2.weight(.semibold))
            TextField("会话名称", text: $title).textFieldStyle(.roundedBorder).focused($focused)
            if suggesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在生成建议…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let suggestion, suggestion != title {
                HStack(spacing: 6) {
                    Text("建议：").font(.callout).foregroundStyle(.secondary)
                    Button(suggestion) { title = suggestion }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Text("仅修改 Perch 中的显示名称，不更改远端标题。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { model.rename(item, title: title); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
            .onAppear { title = item.title; focused = true; loadSuggestion() }
            .onDisappear { suggestionTask?.cancel() }
    }
    /// A user-triggered suggestion follows the same consent gate as automatic
    /// naming and sends the same first-message excerpt to the same endpoint.
    private func loadSuggestion() {
        let settings = ActivitySummarySettings.shared
        let configuration = settings.configuration
        guard configuration.enabled, configuration.nameSessions, configuration.isValid,
              let excerpt = model.namingExcerpt(for: item.reference) else { return }
        suggesting = true
        suggestionTask = Task {
            defer { suggesting = false }
            do {
                let key = try settings.apiKey()
                let name = try await SessionNamingClient().name(configuration: configuration, apiKey: key,
                                                                excerpt: excerpt, language: AppLanguage.current.localization)
                if !Task.isCancelled { suggestion = name }
            } catch {
                // Suggestions stay silent like automatic naming.
            }
        }
    }
}
