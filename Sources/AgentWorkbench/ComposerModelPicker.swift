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
    var layout: ComposerModelPickerLayout = .combined
    var usesDefaultModel = false
    var onUseDefaultModel: (() -> Void)?
    let scope: String
    let onSelectModel: (AgentModel) -> Void
    let onSelectThinking: (ThinkingLevel) -> Void
    @State private var presented = false
    @State private var thinkingPresented = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var modelTitle: String { model?.name ?? (modelID.isEmpty ? L("默认模型") : modelID) }
    private var thinkingTitle: String {
        guard let model else { return modelID.isEmpty ? L("模型默认") : L("不可调") }
        guard model.supportsThinking else { return L("不可调") }
        return model.resolve(thinking)?.label ?? L("默认")
    }

    var body: some View {
        if layout == .combined {
            ModelControlWidth(maximum: 320) {
                Button { presented.toggle() } label: {
                    HStack(spacing: 6) {
                        ModelControlWidth(maximum: 170) {
                            Text(modelTitle)
                                .font(.system(size: WorkbenchTheme.Composer.text, weight: .medium))
                                .foregroundStyle(WorkbenchTheme.ink)
                                .lineLimit(1).truncationMode(.tail)
                        }.layoutPriority(1)
                        // The reasoning level rides along as a tonal badge, never
                        // competing with the model name (PI's chip contract).
                        if let model, model.supportsThinking, unavailableReason == nil,
                           model.resolve(thinking) != .off, model.resolve(thinking) != ThinkingLevel.none {
                            Text(verbatim: model.resolve(thinking)?.rawValue ?? thinkingTitle)
                                .font(.system(size: WorkbenchTheme.Composer.metadata))
                                .foregroundStyle(WorkbenchTheme.quiet)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(WorkbenchTheme.Fill.surface))
                                .fixedSize()
                        }
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(presented ? 180 : 0))
                            .animation(reduceMotion ? nil : .easeOut(duration: WorkbenchTheme.Composer.motion), value: presented)
                    }
                    .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
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

/// PI's two-pane menu: source rail, compact single-line model rows, then reasoning.
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
    @State private var highlight = -1
    @State private var sectionStep: CGFloat = 6
    @State private var appeared = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var recents = RecentModelsStore.shared

    private static let recentSection = "\u{1}recent"
    private var model: AgentModel? { models.first { $0.id == modelID } }
    private var providers: [String] {
        // PI preserves the configured source order; the runtime catalog is ours.
        var seen = Set<String>()
        return models.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }
    private var recentModels: [AgentModel] { recents.models(from: models) }
    private var sections: [String] { (recentModels.isEmpty ? [] : [Self.recentSection]) + providers }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showRail: Bool { sections.count > 1 }
    private var activeSection: String {
        if let section, sections.contains(section) { return section }
        if !recentModels.isEmpty { return Self.recentSection }
        if let selected = model?.provider, providers.contains(selected) { return selected }
        return providers.first ?? Self.recentSection
    }
    private var paneHeight: CGFloat {
        let specialRows = (onUseDefaultModel == nil ? 0 : 1) + (onUseSessionModel == nil ? 0 : 1)
        let count = max(sections.count, recentModels.count + specialRows,
                        providers.map { provider in models.filter { $0.provider == provider }.count + specialRows }.max() ?? 1)
        return min(WorkbenchTheme.Composer.paneMaximum, CGFloat(count) * 30 + 4)
    }
    private var visibleModels: [AgentModel] {
        if searching { return providers.flatMap { provider in matches(models.filter { $0.provider == provider }) } }
        if activeSection == Self.recentSection { return recentModels }
        return models.filter { $0.provider == activeSection }
    }
    private func matches(_ list: [AgentModel]) -> [AgentModel] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return list }
        return list.filter { "\($0.name) \($0.id) \($0.provider)".localizedCaseInsensitiveContains(search) }
    }
    private func modelKey(_ option: AgentModel) -> String { option.provider + "\u{0}" + option.id }
    private func select(_ option: AgentModel) {
        guard disabledReason == nil else { return }
        onSelectModel(option)
        recents.record(option)
        query = ""; highlight = -1
        if layout == .split { dismiss() }
    }
    private func selectSection(_ id: String) {
        let from = sections.firstIndex(of: activeSection) ?? 0
        let to = sections.firstIndex(of: id) ?? 0
        sectionStep = to < from ? -6 : 6
        section = id; query = ""; highlight = -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let unavailableReason {
                Text(unavailableReason).font(.system(size: WorkbenchTheme.Composer.text))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(14)
            } else {
                searchHeader
                if let catalogError {
                    Text(catalogError).font(.system(size: WorkbenchTheme.Composer.metadata)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 6)
                }
                HStack(alignment: .top, spacing: 0) {
                    if showRail { rail }
                    ScrollViewReader { proxy in
                        ScrollView {
                            modelPane.id(searching ? "search" : activeSection)
                                .transition(.opacity.combined(with: .offset(y: sectionStep)))
                        }
                        .onChange(of: activeSection) { _, _ in proxy.scrollTo("model-pane-top", anchor: .top) }
                        .onChange(of: highlight) { _, index in
                            if visibleModels.indices.contains(index) { proxy.scrollTo(modelKey(visibleModels[index])) }
                        }
                    }.frame(height: paneHeight)
                }.padding(6)
                if layout == .combined, let model, model.thinking.count > 1 {
                    Divider()
                    ComposerThinkingControl(model: model, current: thinking, disabled: disabledReason != nil,
                                            onSelect: onSelectThinking)
                        .id(model.provider + ":" + model.id)
                }
            }
            if let disabledReason {
                Label(disabledReason, systemImage: "lock")
                    .font(.system(size: WorkbenchTheme.Composer.metadata)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 8)
            }
            Text(scope).font(.system(size: WorkbenchTheme.Composer.metadata)).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: showRail ? 420 : 320)
        .opacity(appeared ? 1 : 0).scaleEffect(appeared ? 1 : 0.985, anchor: .bottomTrailing)
        .offset(y: appeared ? 0 : 4)
        .animation(reduceMotion ? nil : .easeOut(duration: WorkbenchTheme.Composer.motion), value: searching ? "search" : activeSection)
        .onAppear {
            searchFocused = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: WorkbenchTheme.Composer.motion)) { appeared = true }
        }
        .onChange(of: query) { _, _ in highlight = -1 }
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { key in
            guard searchFocused else { return .ignored }
            if key.key == .return {
                if visibleModels.indices.contains(highlight) { select(visibleModels[highlight]) }
                return .handled
            }
            guard !visibleModels.isEmpty else { return .handled }
            let delta = key.key == .downArrow ? 1 : -1
            let base = highlight < 0 ? (delta > 0 ? -1 : visibleModels.count) : highlight
            highlight = (base + delta + visibleModels.count) % visibleModels.count
            return .handled
        }
        .onExitCommand {
            if searching && searchFocused { query = ""; highlight = -1 }
            else { dismiss() }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.tertiary)
            TextField(L("搜索模型"), text: $query).textFieldStyle(.plain).focused($searchFocused)
                .font(.system(size: WorkbenchTheme.Composer.text))
                .accessibilityIdentifier("model-thinking-search")
            if !query.isEmpty {
                Button { query = ""; highlight = -1; searchFocused = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                }.buttonStyle(.plain).accessibilityLabel(L("清除搜索"))
            }
        }.padding(.leading, 14).padding(.trailing, 10).frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(WorkbenchTheme.Stroke.hairline).frame(height: 1) }
    }

    private var modelPane: some View {
        VStack(spacing: 2) {
            Color.clear.frame(height: 0).id("model-pane-top")
            if !searching, let onUseDefaultModel {
                ComposerModelOptionRow(title: L("使用默认模型"), selected: usesDefaultModel) {
                    onUseDefaultModel()
                    if layout == .split { dismiss() }
                }.disabled(disabledReason != nil).accessibilityIdentifier("model-thinking-default")
            }
            if !searching, let onUseSessionModel {
                ComposerModelOptionRow(title: L("沿用会话模型"), selected: usesSessionModel) {
                    onUseSessionModel()
                    if layout == .split { dismiss() }
                }.disabled(disabledReason != nil).accessibilityIdentifier("model-thinking-inherit")
            }
            if searching {
                ForEach(providers, id: \.self) { provider in
                    let options = matches(models.filter { $0.provider == provider })
                    if !options.isEmpty {
                        Text(provider).font(.system(size: WorkbenchTheme.Composer.metadata)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 1)
                        ForEach(options.indices, id: \.self) { index in modelRow(options[index], showProvider: false) }
                    }
                }
            } else {
                ForEach(visibleModels.indices, id: \.self) { index in
                    modelRow(visibleModels[index], showProvider: activeSection == Self.recentSection)
                }
            }
            if visibleModels.isEmpty {
                Text(models.isEmpty ? L("暂无可用模型") : L("没有匹配的模型"))
                    .font(.system(size: WorkbenchTheme.Composer.text)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 28)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, showRail ? 6 : 0)
    }

    private var rail: some View {
        let activeIndex = searching ? nil : sections.firstIndex(of: activeSection)
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(sections, id: \.self) { id in
                    let count = id == Self.recentSection ? nil : matches(models.filter { $0.provider == id }).count
                    let active = !searching && activeSection == id
                    ComposerModelRailRow(label: id == Self.recentSection ? L("最近使用") : id,
                                         count: count, active: active,
                                         dimmed: searching && (id == Self.recentSection || count == 0)) { selectSection(id) }
                        .accessibilityIdentifier("model-source:" + id)
                }
            }
            .padding(.trailing, 6)
            .overlay(alignment: .topLeading) {
                Capsule().fill(WorkbenchTheme.ink).frame(width: 2, height: 12)
                    .offset(y: CGFloat(activeIndex ?? 0) * 30 + 8).opacity(activeIndex == nil ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: WorkbenchTheme.Composer.motion), value: activeIndex)
                    .allowsHitTesting(false)
            }
        }.scrollIndicators(.hidden).frame(width: WorkbenchTheme.Composer.railWidth, height: paneHeight)
            .overlay(alignment: .trailing) { Rectangle().fill(WorkbenchTheme.Stroke.hairline).frame(width: 1) }
    }

    private func modelRow(_ option: AgentModel, showProvider: Bool) -> some View {
        ComposerModelOptionRow(title: option.name,
                               provider: showProvider ? option.provider : nil,
                               reasoning: !showProvider && option.hasThinkingCapability == true,
                               vision: !showProvider && option.hasVisionCapability == true,
                               context: showProvider ? nil : option.contextWindow.map(WorkbenchTheme.Composer.contextLabel),
                               selected: !usesDefaultModel && option.id == modelID,
                               highlighted: visibleModels.indices.contains(highlight)
                                 && modelKey(visibleModels[highlight]) == modelKey(option)) { select(option) }
            .id(modelKey(option)).help(option.id).disabled(disabledReason != nil)
            .accessibilityIdentifier("model-option:\(option.provider):\(option.id)")
    }
}

private struct ComposerModelOptionRow: View {
    let title: String
    var provider: String? = nil
    var reasoning = false
    var vision = false
    var context: String? = nil
    let selected: Bool
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false
    @UILocalization private var L
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: WorkbenchTheme.Composer.text, weight: selected ? .medium : .regular))
                    .foregroundStyle(WorkbenchTheme.ink).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if let provider { Text(provider).lineLimit(1).truncationMode(.tail) }
                    if reasoning { Image(systemName: "sparkles").font(.system(size: 12)).help(L("推理")).accessibilityLabel(L("推理")) }
                    if vision { Image(systemName: "eye").font(.system(size: 12)).help(L("视觉")).accessibilityLabel(L("视觉")) }
                    if let context { Text(context).monospacedDigit() }
                }.font(.system(size: WorkbenchTheme.Composer.metadata)).foregroundStyle(.tertiary).fixedSize()
                Image(systemName: "checkmark").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkbenchTheme.ink).opacity(selected ? 1 : 0)
                    .frame(width: 13).accessibilityHidden(true)
            }.padding(.horizontal, 8).frame(height: WorkbenchTheme.Composer.rowHeight).contentShape(Rectangle())
                .background(hovering || highlighted ? WorkbenchTheme.Fill.hover : .clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Composer.CompactShape.cornerRadius))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ComposerModelRailRow: View {
    let label: String
    let count: Int?
    let active: Bool
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count {
                    Text(verbatim: "\(count)").font(.system(size: WorkbenchTheme.Composer.metadata, weight: .regular))
                        .foregroundStyle(.tertiary).monospacedDigit()
                }
            }.font(.system(size: WorkbenchTheme.Composer.text, weight: active ? .medium : .regular))
                .foregroundStyle(active || hovering ? WorkbenchTheme.ink : WorkbenchTheme.quiet)
                .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                .background(hovering ? WorkbenchTheme.Fill.hover : .clear,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Composer.CompactShape.cornerRadius))
                .opacity(dimmed ? 0.38 : 1)
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(active ? .isSelected : [])
    }
}
