import SwiftUI
import WorkbenchCore

struct ModelPicker: View {
    let models: [ModelOption]
    @Binding var selection: String
    var current = ""
    @State private var presented = false
    private var effective: String { selection.isEmpty ? current : selection }
    private var option: ModelOption? { models.first { $0.id == effective } }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                if let option { Text(option.provider).foregroundStyle(.secondary); Text("/").foregroundStyle(.tertiary) }
                Text(option?.name ?? (effective.isEmpty ? "默认模型" : String(effective.split(separator: "/").last ?? "")))
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 7).padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(presented ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help("选择模型 · \(effective)").accessibilityLabel("选择模型")
            .popover(isPresented: $presented, arrowEdge: .top) {
                ModelPickerPanel(models: models, selection: $selection, current: current) { presented = false }
            }
    }
}

private struct ModelPickerPanel: View {
    let models: [ModelOption]
    @Binding var selection: String
    let current: String
    let dismiss: () -> Void
    @State private var query = ""
    @State private var provider: String?
    @FocusState private var focused: Bool
    private var groups: [ModelProviderGroup] {
        ModelCatalog.groups(models.filter { provider == nil || $0.provider == provider }, matching: query)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let provider {
                HStack {
                    Button { self.provider = nil; query = ""; focused = true } label: {
                        Label("Provider", systemImage: "chevron.left")
                    }.buttonStyle(.plain).accessibilityLabel("返回 Provider 列表")
                    Spacer()
                    Text(provider).fontWeight(.medium).lineLimit(1)
                }.font(.system(size: 13)).padding(14)
                Divider()
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(provider == nil ? "搜索 Provider 或模型" : "搜索模型", text: $query)
                    .textFieldStyle(.plain).focused($focused)
            }.font(.system(size: 13)).padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if provider == nil && query.isEmpty {
                        ModelPickerRow(name: current.isEmpty ? "使用默认模型" : "沿用会话模型", detail: current.isEmpty ? nil : current,
                                       selected: selection.isEmpty) { selection = ""; dismiss() }
                    }
                    ForEach(groups) { group in
                        if provider == nil {
                            ModelPickerRow(name: group.id, detail: "\(group.models.count) 个模型",
                                           selected: group.models.contains { $0.id == (selection.isEmpty ? current : selection) },
                                           disclosure: true) {
                                provider = group.id; query = ""; focused = true
                            }
                        } else {
                            ForEach(group.models) { model in
                                ModelPickerRow(name: model.name,
                                               detail: model.capabilities.contains("image_in") ? "支持图片" : nil,
                                               selected: selection == model.id) { selection = model.id; dismiss() }
                            }
                        }
                    }
                    if groups.isEmpty { Text(models.isEmpty ? "暂无可用模型" : "没有匹配的模型").font(.system(size: 12)).foregroundStyle(.secondary).padding(16) }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }.frame(height: 340)
            Divider()
            Text("选择将用于下一条消息").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.frame(width: 340).background(Color(nsColor: .controlBackgroundColor)).onAppear { focused = true }
    }
}
private struct ModelPickerRow: View {
    let name: String
    let detail: String?
    let selected: Bool
    var disclosure = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                if disclosure { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                .background(hovered || selected ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}
