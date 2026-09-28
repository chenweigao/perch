import SwiftUI
import WorkbenchCore

struct GroupSuggestionsSheet: View {
    @UILocalization private var L
    @ObservedObject var model: WorkbenchModel
    @ObservedObject private var settings = ActivitySummarySettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [GroupSuggestion] = []
    @State private var selected = Set<String>()
    @State private var loading = false
    @State private var generated = false
    @State private var error: String?
    @State private var showSettings = false
    @State private var requestTask: Task<Void, Never>?
    @State private var applied = false
    private var configured: Bool { settings.configuration.enabled && settings.configuration.isValid }
    private var proposedInput: GroupingInput { GroupingInput(groups: model.workspace.groups, sessions: model.allSessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Agent 帮我归组").font(.title2.weight(.medium))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("按任务目标建议关联，可同时属于多个组。已有归组保留，信息不足时不强行归类。")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("正在生成归组建议…") }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if applied { Label("已应用归组建议", systemImage: "checkmark.circle") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if generated && suggestions.isEmpty { Text("现有信息不足以建议新的关联。可以补充任务组目标或会话标题后重试。") }
                    ForEach(suggestions) { suggestion in
                        Toggle(isOn: Binding(get: { selected.contains(suggestion.id) }, set: {
                            if $0 { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.allSessions.first { $0.id == suggestion.sessionID }?.title ?? suggestion.sessionID).fontWeight(.medium)
                                Text("→ \(model.workspace.groups.first { $0.id == suggestion.groupID }?.name ?? "")")
                                Text(suggestion.reason).foregroundStyle(.secondary).textSelection(.enabled)
                            }.font(.system(size: 12))
                        }.toggleStyle(.checkbox).disabled(applied)
                    }
                    if !generated {
                        let preview = proposedInput
                        Text("本批最多 40 个未归档会话、24 个进行中的任务组。")
                        Text("点击生成后，将以下标题、目录末三级、已有归属、组名、目标与示例标题发送到你配置的摘要服务；不发送对话正文或工具输出。")
                            .foregroundStyle(.secondary)
                        if preview.groups.isEmpty { Text("请先新建一个任务组并填写目标。").foregroundStyle(.orange) }
                        DisclosureGroup("查看本批内容 · \(preview.sessions.count) 个会话 · \(preview.groups.count) 个任务组") {
                            ForEach(preview.groups, id: \.id) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).fontWeight(.medium)
                                    Text(group.goal)
                                    ForEach(Array(group.examples.enumerated()), id: \.offset) { _, title in Text(title).foregroundStyle(.secondary) }
                                }.padding(.vertical, 5)
                            }
                            Divider()
                            ForEach(preview.sessions, id: \.id) { session in
                                Text("\(session.title) · \(session.directory)").padding(.vertical, 3)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }.frame(minHeight: 240)
            HStack {
                if configured {
                    Button(generated ? "重新生成" : "生成建议") { generate() }
                        .disabled(loading || applied || proposedInput.groups.isEmpty || proposedInput.sessions.isEmpty)
                } else { Button("配置摘要服务…") { showSettings = true } }
                if model.groupingUndo != nil {
                    Button("撤销上次归组") {
                        if model.undoGroupSuggestions() { applied = false; suggestions = []; generated = false; error = nil }
                        else { error = L("归组后关联已被修改，为保留你的调整，未执行撤销。") }
                    }
                }
                Spacer()
                if !suggestions.isEmpty {
                    Button("应用所选 \(selected.count) 项") {
                        let count = model.applyGroupSuggestions(suggestions.filter { selected.contains($0.id) })
                        applied = count > 0
                        if !applied { error = L("关联已变化，请重新生成建议。") }
                    }.disabled(selected.isEmpty || applied || loading)
                }
            }
        }.padding(24).frame(width: 650, height: 600)
            .sheet(isPresented: $showSettings) { ActivitySummarySettingsSheet() }
            .onDisappear { requestTask?.cancel() }
    }

    private func generate() {
        let batch = proposedInput
        loading = true; error = nil; suggestions = []; selected = []; generated = false
        let configuration = settings.configuration
        let revision = settings.revision
        requestTask = Task { @MainActor in
            defer { loading = false }
            do {
                let key = try await settings.apiKey()
                try Task.checkCancellation()
                guard settings.revision == revision else { throw CancellationError() }
                let result = try await GroupingClient().suggest(configuration: configuration, apiKey: key,
                    input: batch, language: AppLanguage.current.localization)
                try Task.checkCancellation()
                guard settings.revision == revision else { throw CancellationError() }
                suggestions = result; selected = Set(result.map(\.id)); generated = true
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
