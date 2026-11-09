import SwiftUI
import WorkbenchCore

enum ComposerModelPickerLayout {
    case split
    case combined
}

struct ComposerModelPicker: View {
    @UILocalization private var L
    let models: [AgentModel]
    let modelID: String
    let thinking: ThinkingLevel?
    var disabledReason: String?
    var unavailableReason: String?
    var catalogError: String?
    var onRefreshCatalog: (() async -> Void)?
    var sessionModel: String?
    var usesSessionModel = false
    var onUseSessionModel: (() -> Void)?
    var layout: ComposerModelPickerLayout = .split
    var usesDefaultModel = false
    var onUseDefaultModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    @State private var presented = false
    @State private var thinkingPresented = false
    @State private var hovering = false

    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var modelTitle: String { model?.name ?? (modelID.isEmpty ? L("默认模型") : modelID) }
    private var thinkingTitle: String {
        guard let model else { return modelID.isEmpty ? L("模型默认") : L("不可调") }
        guard model.supportsThinking else { return L("不可调") }
        return model.resolve(thinking)?.label ?? L("默认")
    }

    var body: some View {
        if layout == .combined {
            ModelControlWidth(maximum: 300) {
                Button { presented.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(modelTitle)
                            .font(.system(size: WorkbenchTheme.Typography.body, weight: .medium))
                            .foregroundStyle(WorkbenchTheme.ink)
                            .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                        // The reasoning level rides along as a tonal badge, never
                        // competing with the model name (PI's chip contract).
                        if let model, model.supportsThinking, unavailableReason == nil {
                            Text(verbatim: thinkingTitle)
                                .font(.system(size: WorkbenchTheme.Typography.caption - 1))
                                .foregroundStyle(WorkbenchTheme.quiet)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(WorkbenchTheme.Fill.surface))
                                .fixedSize()
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 5)
                    .background(Capsule().fill(presented ? WorkbenchTheme.Fill.selected : hovering ? WorkbenchTheme.Fill.hover : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(disabledReason ?? L("模型与思考"))
                .accessibilityLabel(L("模型与思考"))
                .accessibilityValue("\(modelTitle) · \(thinkingTitle)")
                .accessibilityIdentifier("composer-model-thinking")
                .popover(isPresented: $presented, arrowEdge: .top) {
                    panel.task { await onRefreshCatalog?() }
                }
            }
        } else {
            HStack(spacing: 12) {
                ModelControlWidth {
                    Button { presented.toggle() } label: {
                        HStack(spacing: 5) {
                            Text(modelTitle).lineLimit(1).truncationMode(.middle)
                            chevron
                        }
                        .font(.system(size: WorkbenchTheme.Typography.body))
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("选择模型") + " · " + modelTitle)
                    .accessibilityLabel(L("选择模型"))
                    .accessibilityValue(modelTitle)
                    .accessibilityIdentifier("composer-model-thinking")
                    .popover(isPresented: $presented, arrowEdge: .top) {
                        panel.task { await onRefreshCatalog?() }
                    }
                }
                if let model, model.supportsThinking, unavailableReason == nil {
                    Button { thinkingPresented.toggle() } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: thinkingTitle)
                            chevron
                        }
                        .font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
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
                                .font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(12).frame(width: 240)
                            .onExitCommand { thinkingPresented = false }
                    }
                }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var panel: ComposerModelPanel {
        ComposerModelPanel(models: models, modelID: modelID, thinking: thinking,
                           disabledReason: disabledReason, unavailableReason: unavailableReason,
                           catalogError: catalogError, sessionModel: sessionModel, usesSessionModel: usesSessionModel,
                           onUseSessionModel: onUseSessionModel, layout: layout,
                           usesDefaultModel: usesDefaultModel, onUseDefaultModel: onUseDefaultModel,
                           scope: scope, onSelectModel: onSelectModel, onSelectThinking: onSelectThinking,
                           dismiss: { presented = false })
    }
}

/// Recently chosen models, most recent first, capped like PI's recent rail.
final class RecentModelsStore: ObservableObject {
    static let shared = RecentModelsStore()
    private let key = "perch.recentModels"
    private let limit = 6
    @Published private(set) var entries: [String] = []
    private init() { entries = UserDefaults.standard.stringArray(forKey: key) ?? [] }
    func record(_ model: AgentModel) {
        let entry = model.provider + "\u{0}" + model.id
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        UserDefaults.standard.set(entries, forKey: key)
    }
    func models(from catalog: [AgentModel]) -> [AgentModel] {
        entries.compactMap { entry in
            let parts = entry.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return catalog.first { $0.provider == parts[0] && $0.id == parts[1] }
        }
    }
}

/// PI's two-pane model menu: a source rail (recent + providers with counts)
/// on the left, the selected source's rows on the right, reasoning below.
private struct ComposerModelPanel: View {
    @UILocalization private var L
    let models: [AgentModel]
    let modelID: String
    let thinking: ThinkingLevel?
    let disabledReason: String?
    let unavailableReason: String?
    let catalogError: String?
    let sessionModel: String?
    let usesSessionModel: Bool
    let onUseSessionModel: (() -> Void)?
    let layout: ComposerModelPickerLayout
    let usesDefaultModel: Bool
    let onUseDefaultModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var section: String? = nil
    @ObservedObject private var recents = RecentModelsStore.shared

    private static let recentSection = "\u{1}recent"
    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var providers: [String] { Array(Set(models.map(\.provider))).sorted() }
    private var recentModels: [AgentModel] { recents.models(from: models) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showRail: Bool { providers.count + (recentModels.isEmpty ? 0 : 1) > 1 }
    private var activeSection: String {
        if let section, section == Self.recentSection && !recentModels.isEmpty { return section }
        if let section, providers.contains(section) { return section }
        if !recentModels.isEmpty { return Self.recentSection }
        if let selected = model?.provider, providers.contains(selected) { return selected }
        return providers.first ?? Self.recentSection
    }
    private func matches(_ list: [AgentModel]) -> [AgentModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return list }
        return list.filter {
            "\($0.name) \($0.id) \($0.provider)".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unavailableReason {
                Text(unavailableReason).font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(14)
            }
            if unavailableReason == nil {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索模型或渠道", text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("model-thinking-search")
                }.font(.system(size: WorkbenchTheme.Typography.body)).padding(14)
                if let catalogError {
                    Text(catalogError).font(.system(size: WorkbenchTheme.Typography.secondary)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 8)
                }
                HStack(alignment: .top, spacing: 0) {
                    if showRail { rail }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if let onUseDefaultModel {
                                ModelPickerRow(title: Text("使用默认模型"), detail: nil,
                                               selected: usesDefaultModel) {
                                    onUseDefaultModel()
                                    if layout == .split { dismiss() }
                                }
                                    .disabled(disabledReason != nil).padding(.horizontal, 6)
                                    .accessibilityIdentifier("model-thinking-default")
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
                            if searching {
                                // Search spans every source; provider labels keep the groups apart.
                                ForEach(providers, id: \.self) { group in
                                let groupMatches = matches(models.filter { $0.provider == group })
                                if !groupMatches.isEmpty {
                                    Text(group).font(.system(size: WorkbenchTheme.Typography.caption))
                                        .foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(groupMatches) { option in modelRow(option, showProvider: false) }
                                }
                            }
                            } else if activeSection == Self.recentSection {
                                ForEach(recentModels) { option in modelRow(option, showProvider: true) }
                            } else {
                                ForEach(matches(models.filter { $0.provider == activeSection })) { option in
                                    modelRow(option, showProvider: false)
                                }
                            }
                            if searching, providers.allSatisfy({ provider in matches(models.filter { $0.provider == provider }).isEmpty }) {
                                Text(models.isEmpty
                                     ? L(onUseDefaultModel == nil ? "尚未读取到模型目录，可继续使用会话模型。" : "尚未读取到模型目录，可继续使用默认模型。")
                                     : L("没有匹配的模型"))
                                    .font(.system(size: WorkbenchTheme.Typography.body)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                        }.padding(6)
                    }.frame(height: 240)
                }
                Divider()
                if layout == .combined {
                    ThinkingPicker(model: model, current: thinking, disabled: disabledReason != nil,
                                   unavailableReason: modelID.isEmpty ? L("使用默认模型时，思考强度由模型决定。") : nil,
                                   onSelect: onSelectThinking)
                        .padding(14)
                    Divider()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let disabledReason {
                    Label(disabledReason, systemImage: "lock")
                } else if layout == .split, let model, !model.supportsThinking, unavailableReason == nil {
                    if model.hasThinkingCapability == true {
                        Text("支持思考，但尚未声明可选档位。请补充 Agent 的模型配置。")
                    } else {
                        Text("此模型未提供思考档位设置。")
                    }
                }
                Text(scope)
            }.font(.system(size: WorkbenchTheme.Typography.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(12)
        }
        .frame(width: showRail ? 420 : 320)
        .onExitCommand(perform: dismiss)
    }

    /// PI's rail: one row per source, provider counts on the trailing edge.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !recentModels.isEmpty {
                railRow(id: Self.recentSection, label: L("最近使用"), count: nil)
            }
            ForEach(providers, id: \.self) { provider in
                let count = searching ? matches(models.filter { $0.provider == provider }).count
                                      : models.filter { $0.provider == provider }.count
                railRow(id: provider, label: provider, count: count)
            }
        }.padding(6).frame(width: 120)
            .overlay(alignment: .trailing) {
                Rectangle().fill(WorkbenchTheme.Stroke.hairline).frame(width: 1)
            }
    }
    private func railRow(id: String, label: String, count: Int?) -> some View {
        let active = !searching && activeSection == id
        return Button {
            section = id
            query = ""
        } label: {
            HStack {
                Text(label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let count {
                    Text(verbatim: "\(count)").foregroundStyle(.tertiary).monospacedDigit()
                }
            }.font(.system(size: WorkbenchTheme.Typography.secondary))
                .foregroundStyle(active ? WorkbenchTheme.ink : WorkbenchTheme.quiet)
                .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                .background(active ? WorkbenchTheme.Fill.selected : .clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.chip))
        }.buttonStyle(.plain)
    }

    private func modelRow(_ option: AgentModel, showProvider: Bool) -> some View {
        var meta: [String] = []
        if showProvider { meta.append(option.provider) }
        if let window = option.contextWindow { meta.append(ContextBudget.short(window)) }
        return ModelPickerRow(title: Text(option.name), detail: meta.isEmpty ? nil : meta.joined(separator: " · "),
                              selected: !usesSessionModel && !usesDefaultModel && option.id == modelID) {
            onSelectModel(option)
            recents.record(option)
            if layout == .split { dismiss() }
        }
            .help(option.id).disabled(disabledReason != nil)
            .accessibilityIdentifier("model-option:\(option.provider):\(option.id)")
    }
}
