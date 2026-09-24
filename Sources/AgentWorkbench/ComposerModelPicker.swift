import SwiftUI
import WorkbenchCore

struct ComposerModelPicker: View {
    @UILocalization private var L
    let models: [AgentModel]
    let modelID: String
    let thinking: ThinkingLevel?
    var disabledReason: String?
    var unavailableReason: String?
    var catalogError: String?
    var sessionModel: String?
    var onUseSessionModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    @State private var presented = false

    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var title: String { model?.name ?? (modelID.isEmpty ? L("选择模型") : modelID) }
    private var thinkingTitle: String {
        if unavailableReason != nil || model?.supportsThinking == false { return L("不可用") }
        guard let model else { return L("未知") }
        return model.resolve(thinking).map { L(key: $0.label) } ?? L("默认")
    }

    private var controlLabel: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.middle).frame(minWidth: 64, alignment: .leading)
            Text("·").foregroundStyle(.tertiary)
            Text("思考：\(thinkingTitle)").foregroundStyle(.secondary).fixedSize()
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String { "\(title) · \(L("思考：\(thinkingTitle)"))" }
    private var helpText: String { "\(L("模型与思考"))\n\(title)\n\(scope)" }

    private var control: some View {
        Button { presented.toggle() } label: { controlLabel }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel(L("模型与思考"))
            .accessibilityValue(summary)
            .accessibilityIdentifier("composer-model-thinking")
    }

    var body: some View {
        ModelControlWidth(maximum: 360) { control }
            .popover(isPresented: $presented, arrowEdge: .top) { panel }
    }

    private var panel: ComposerModelPanel {
        ComposerModelPanel(models: models, modelID: modelID, thinking: thinking,
                           disabledReason: disabledReason, unavailableReason: unavailableReason,
                           catalogError: catalogError, sessionModel: sessionModel,
                           onUseSessionModel: onUseSessionModel, scope: scope,
                           onSelectModel: onSelectModel, onSelectThinking: onSelectThinking,
                           dismiss: { presented = false })
    }
}

private struct ComposerModelPanel: View {
    @UILocalization private var L
    let models: [AgentModel]
    let modelID: String
    let thinking: ThinkingLevel?
    let disabledReason: String?
    let unavailableReason: String?
    let catalogError: String?
    let sessionModel: String?
    let onUseSessionModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var provider = ""

    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var providers: [String] { Array(Set(models.map(\.provider))).sorted() }
    private var matches: [AgentModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter {
            (provider.isEmpty || $0.provider == provider) &&
            (search.isEmpty || "\($0.name) \($0.id) \($0.provider)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模型与思考").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model?.name ?? (modelID.isEmpty ? L("选择模型") : modelID))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        if let model { Text(model.provider).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    Button("完成", action: dismiss).controlSize(.small)
                        .accessibilityIdentifier("model-thinking-done")
                }
                ThinkingPicker(model: model, current: thinking, disabled: disabledReason != nil,
                               unavailableReason: unavailableReason, onSelect: onSelectThinking)
                if let disabledReason {
                    Label(disabledReason, systemImage: "lock")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(16)
            if unavailableReason == nil {
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索模型或渠道", text: $query).textFieldStyle(.plain)
                            .accessibilityIdentifier("model-thinking-search")
                    }
                    Picker("渠道", selection: $provider) {
                        Text("全部渠道").tag("")
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                }.font(.system(size: 13)).padding(14)
                if let catalogError {
                    Text(catalogError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if let onUseSessionModel {
                    ModelPickerRow(title: Text("沿用会话模型"), detail: sessionModel,
                                   selected: modelID == sessionModel, action: onUseSessionModel)
                        .disabled(disabledReason != nil).padding(.horizontal, 6)
                        .accessibilityIdentifier("model-thinking-inherit")
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(providers, id: \.self) { group in
                            ForEach(matches.filter { $0.provider == group }) { option in
                                ModelPickerRow(title: Text(option.name), detail: option.provider,
                                               selected: option.id == modelID) { onSelectModel(option) }
                                    .help(option.id).disabled(disabledReason != nil)
                                    .accessibilityIdentifier("model-option:\(option.provider):\(option.id)")
                            }
                        }
                        if matches.isEmpty {
                            Text(models.isEmpty ? L("尚未读取到模型目录，可继续使用会话模型。") : L("没有匹配的模型"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }.padding(6)
                }.frame(height: 240)
            }
            Divider()
            Text(scope).font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 380)
        .onExitCommand(perform: dismiss)
    }
}
