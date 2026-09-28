import SwiftUI
import WorkbenchCore

struct GroupSuggestionsSheet: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    @ObservedObject private var settings = ActivitySummarySettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var state = GroupSuggestionsState()
    @State private var showSettings = false
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
            if state.loading { ProgressView("正在生成归组建议…") }
            if let error = state.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if state.applied { Label("已应用归组建议", systemImage: "checkmark.circle") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.generated && state.suggestions.isEmpty { Text("现有信息不足以建议新的关联。可以补充任务组目标或会话标题后重试。") }
                    ForEach(state.suggestions) { suggestion in
                        Toggle(isOn: Binding(get: { state.selected.contains(suggestion.id) }, set: {
                            if $0 { state.selected.insert(suggestion.id) } else { state.selected.remove(suggestion.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.allSessions.first { $0.id == suggestion.sessionID }?.title ?? suggestion.sessionID).fontWeight(.medium)
                                Text("→ \(model.workspace.groups.first { $0.id == suggestion.groupID }?.name ?? "")")
                                Text(suggestion.reason).foregroundStyle(.secondary).textSelection(.enabled)
                            }.font(.system(size: 12))
                        }.toggleStyle(.checkbox).disabled(state.applied)
                    }
                    if !state.generated {
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
                    Button(state.generated ? "重新生成" : "生成建议") { generate() }
                        .disabled(state.loading || state.applied || proposedInput.groups.isEmpty || proposedInput.sessions.isEmpty)
                } else { Button("配置摘要服务…") { showSettings = true } }
                if model.groupingUndo != nil {
                    Button("撤销上次归组") {
                        if model.undoGroupSuggestions() { state.reset() }
                        else { state.error = L("归组后关联已被修改，为保留你的调整，未执行撤销。") }
                    }
                }
                Spacer()
                if !state.suggestions.isEmpty {
                    Button("应用所选 \(state.selected.count) 项") {
                        let count = model.applyGroupSuggestions(state.suggestions.filter { state.selected.contains($0.id) })
                        state.applied = count > 0
                        if !state.applied { state.error = L("关联已变化，请重新生成建议。") }
                    }.disabled(state.selected.isEmpty || state.applied || state.loading)
                }
            }
        }.padding(24).frame(width: 650, height: 600)
            .sheet(isPresented: $showSettings) { ActivitySummarySettingsSheet() }
            .task(id: state.request?.id) {
                guard let request = state.request else { return }
                await state.load(request) { request in
                    let key = try await settings.apiKey()
                    try Task.checkCancellation()
                    guard settings.revision == request.revision else { throw CancellationError() }
                    let result = try await GroupingClient().suggest(configuration: request.configuration, apiKey: key,
                        input: request.input, language: request.language)
                    guard settings.revision == request.revision else { throw CancellationError() }
                    return result
                }
            }
    }

    private func generate() {
        state.begin(input: proposedInput, configuration: settings.configuration,
                    revision: settings.revision, language: AppLanguage.current.localization)
    }
}
