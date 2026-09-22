import SwiftUI
import WorkbenchCore

struct ModelPicker: View {
    let models: [ModelOption]
    @Binding var selection: String
    var current = ""
    var effortUnavailable = false
    /// Sheets that pick a model for a new task show the choice as primary text;
    /// the composer row keeps the quiet secondary look.
    var emphasizesSelection = false
    @State private var presented = false
    private var effective: String { selection.isEmpty ? current : selection }
    private var option: ModelOption? { models.first { $0.id == effective } }

    var body: some View {
        ModelControlWidth {
            Button { presented.toggle() } label: {
                HStack(spacing: 5) {
                    if let option {
                        Text(option.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                            .foregroundStyle(emphasizesSelection ? .primary : .secondary)
                        Text("· \(option.provider)").foregroundStyle(.secondary).lineLimit(1)
                    } else if effective.isEmpty {
                        Text("默认模型").foregroundStyle(.secondary)
                    } else {
                        Text(effective).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(emphasizesSelection ? .primary : .secondary)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }.font(.system(size: 12))
                    .padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(Text("选择模型，用于下一条消息"))
                .accessibilityLabel(Text("选择模型"))
                .accessibilityValue(effective)
                .popover(isPresented: $presented, arrowEdge: .top) {
                    ModelPickerPanel(models: models, selection: $selection, current: current, effortUnavailable: effortUnavailable) {
                        presented = false
                    }
                }
        }
    }
}

private struct ModelPickerPanel: View {
    let models: [ModelOption]
    @Binding var selection: String
    let current: String
    var effortUnavailable = false
    let dismiss: () -> Void
    @State private var query = ""
    @State private var provider = ""
    @FocusState private var searchFocused: Bool
    private var matches: [ModelOption] {
        ModelCatalog.groups(models, matching: query).flatMap(\.models)
            .filter { provider.isEmpty || $0.provider == provider }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索模型或渠道", text: $query).textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                Picker("渠道", selection: $provider) {
                    Text("全部渠道").tag("")
                    ForEach(ModelCatalog.groups(models)) { group in
                        Text(group.id).tag(group.id)
                    }
                }.pickerStyle(.menu)
            }.font(.system(size: 13)).padding(14)
            Divider()
            if effortUnavailable {
                Text("此模型未提供思考档位设置。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }
            ModelPickerRow(title: current.isEmpty ? Text("使用默认模型") : Text("沿用会话模型"),
                           detail: current.isEmpty ? nil : current, selected: selection.isEmpty) {
                selection = ""
                dismiss()
            }.padding(6)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { model in
                        ModelPickerRow(title: Text(model.name), detail: model.provider,
                                       selected: selection == model.id) {
                            selection = model.id
                            dismiss()
                        }.help(model.id)
                    }
                    if matches.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if models.isEmpty {
                                Text("暂无可用模型")
                                Text("当前连接尚未提供模型列表，可沿用会话或默认模型。")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("没有匹配的模型")
                                Text("请调整搜索词或渠道筛选。")
                                    .foregroundStyle(.secondary)
                            }
                        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(6)
            }.frame(height: 280)
            Divider()
            Text("用于下一条消息").font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.frame(width: 360)
            .onAppear { searchFocused = true }
            .onExitCommand(perform: dismiss)
    }
}

private struct ModelPickerRow: View {
    let title: Text
    let detail: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    title.font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .background(hovered || selected ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Cap long model labels without reserving empty space after short names.
struct ModelControlWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: min(proposal.width ?? 240, 240), height: proposal.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
