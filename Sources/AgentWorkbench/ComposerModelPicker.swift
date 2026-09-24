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
    var usesSessionModel = false
    var onUseSessionModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    @State private var presented = false
    @State private var thinkingPresented = false

    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var title: String { model?.name ?? (modelID.isEmpty ? L("选择模型") : modelID) }
    private var thinkingTitle: String {
        model?.resolve(thinking).map { L(key: $0.label) } ?? L("默认")
    }

    var body: some View {
        HStack(spacing: 12) {
            ModelControlWidth {
                Button { presented.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(title).lineLimit(1).truncationMode(.middle)
                        chevron
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("选择模型"))
                .accessibilityLabel(L("选择模型"))
                .accessibilityValue(title)
                .accessibilityIdentifier("composer-model-thinking")
                .popover(isPresented: $presented, arrowEdge: .top) { panel }
            }
            if let model, model.supportsThinking, unavailableReason == nil {
                Button { thinkingPresented.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("思考：\(thinkingTitle)")
                        chevron
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize()
                .help(disabledReason ?? L("思考强度"))
                .accessibilityLabel(L("思考强度"))
                .accessibilityValue(thinkingTitle)
                .accessibilityIdentifier("composer-thinking")
                .popover(isPresented: $thinkingPresented, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        ThinkingPicker(model: model, current: thinking, disabled: disabledReason != nil) {
                            onSelectThinking($0)
                            thinkingPresented = false
                        }
                        Divider()
                        Text(disabledReason ?? scope)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(width: 240)
                        .onExitCommand { thinkingPresented = false }
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var panel: ComposerModelPanel {
        ComposerModelPanel(models: models, modelID: modelID,
                           disabledReason: disabledReason, unavailableReason: unavailableReason,
                           catalogError: catalogError, sessionModel: sessionModel, usesSessionModel: usesSessionModel,
                           onUseSessionModel: onUseSessionModel, scope: scope,
                           onSelectModel: onSelectModel,
                           dismiss: { presented = false })
    }
}

private struct ComposerModelPanel: View {
    @UILocalization private var L
    let models: [AgentModel]
    let modelID: String
    let disabledReason: String?
    let unavailableReason: String?
    let catalogError: String?
    let sessionModel: String?
    let usesSessionModel: Bool
    let onUseSessionModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
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
            if let unavailableReason {
                Text(unavailableReason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(14)
            }
            if unavailableReason == nil {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索模型或渠道", text: $query).textFieldStyle(.plain)
                            .accessibilityIdentifier("model-thinking-search")
                    }
                    if providers.count > 1 {
                        HStack {
                            Picker("渠道", selection: $provider) {
                                Text("全部渠道").tag("")
                                ForEach(providers, id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.menu).labelsHidden().fixedSize()
                                .accessibilityLabel(L("渠道"))
                            Spacer()
                        }
                    }
                }.font(.system(size: 13)).padding(14)
                if let catalogError {
                    Text(catalogError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 8)
                }
                if let onUseSessionModel {
                    ModelPickerRow(title: Text("沿用会话模型"), detail: sessionModel,
                                   selected: usesSessionModel) {
                        onUseSessionModel()
                        dismiss()
                    }
                        .disabled(disabledReason != nil).padding(.horizontal, 6)
                        .accessibilityIdentifier("model-thinking-inherit")
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(providers, id: \.self) { group in
                            ForEach(matches.filter { $0.provider == group }) { option in
                                ModelPickerRow(title: Text(option.name), detail: option.provider,
                                               selected: !usesSessionModel && option.id == modelID) {
                                    onSelectModel(option)
                                    dismiss()
                                }
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
            VStack(alignment: .leading, spacing: 6) {
                if let disabledReason {
                    Label(disabledReason, systemImage: "lock")
                } else if let model, !model.supportsThinking, unavailableReason == nil {
                    Text("此模型未提供思考档位设置。")
                }
                Text(scope)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(12)
        }
        .frame(width: 320)
        .onExitCommand(perform: dismiss)
    }
}
