import SwiftUI
import WorkbenchCore

enum PermissionPickerLayout {
    case compact
    case form
}

struct PermissionPicker: View {
    let provider: SessionKind
    let capability: PermissionCapability
    let layout: PermissionPickerLayout
    let disabled: Bool
    let allowsSelection: Bool
    let onSelect: (String) -> Void
    @State private var pendingDangerousOption: PermissionOption?
    @State private var showingDetails = false

    init(provider: SessionKind, capability: PermissionCapability,
         layout: PermissionPickerLayout = .compact, disabled: Bool = false,
         allowsSelection: Bool? = nil, onSelect: @escaping (String) -> Void) {
        self.provider = provider
        self.capability = capability
        self.layout = layout
        self.disabled = disabled
        self.allowsSelection = allowsSelection ?? capability.canSelect
        self.onSelect = onSelect
    }

    private var options: [PermissionOption] {
        PermissionCatalog.resolvedOptions(capability, for: provider)
    }

    private var selected: PermissionOption? {
        PermissionCatalog.option(capability.selected, for: provider)
    }

    private var title: String {
        selected?.title ?? L("沿用会话设置")
    }

    private var detail: String {
        selected?.detail ?? L("Perch 不会覆盖此会话已有的权限设置。")
    }

    private var risk: PermissionRisk {
        selected?.risk ?? .standard
    }

    var body: some View {
        Group {
            if layout == .form {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(provider.label)
                        Spacer()
                        control
                    }
                    Text(detail)
                        .font(.caption).foregroundStyle(riskColor)
                    Text(capability.scope.label)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                control
            }
        }
        .alert(L("确认高风险权限"), isPresented: Binding(
            get: { pendingDangerousOption != nil },
            set: { if !$0 { pendingDangerousOption = nil } }
        )) {
            Button(L("取消"), role: .cancel) { pendingDangerousOption = nil }
            if let option = pendingDangerousOption {
                Button(L("启用“\(option.title)”"), role: .destructive) {
                    pendingDangerousOption = nil
                    onSelect(option.id)
                }
            }
        } message: {
            if let option = pendingDangerousOption {
                Text(option.detail + "\n" + L("此模式可能允许 Agent 在不询问你的情况下执行危险操作。"))
            }
        }
    }

    @ViewBuilder private var control: some View {
        if allowsSelection && !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    Button {
                        choose(option)
                    } label: {
                        if option.id == capability.selected {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
                Divider()
                Text(capability.scope.label)
                Text(detail)
            } label: {
                permissionLabel
            }
            .menuStyle(.borderlessButton).menuIndicator(layout == .compact ? .hidden : .visible).fixedSize()
            .disabled(disabled)
            .help(title + "\n" + detail + "\n" + capability.scope.label)
            .accessibilityLabel(L("选择权限级别"))
        } else {
            Button { showingDetails.toggle() } label: { permissionLabel }
                .buttonStyle(.plain)
                .help(title + "\n" + detail)
                .accessibilityLabel(L("权限级别：\(title)"))
                .popover(isPresented: $showingDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.headline)
                        Text(detail)
                        Text(capability.scope.label).foregroundStyle(.secondary)
                    }.font(.callout).padding(16).frame(width: 280, alignment: .leading)
                }
        }
    }

    private var permissionLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if layout == .form || risk != .standard { Text(title) }
        }
        .font(.system(size: layout == .compact ? 12 : 13))
        .foregroundStyle(riskColor)
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
        .fixedSize()
    }

    private var symbol: String {
        switch risk {
        case .standard: return selected == nil ? "shield" : "checkmark.shield"
        case .elevated: return "exclamationmark.shield"
        case .dangerous: return "shield.slash.fill"
        }
    }

    private var riskColor: Color {
        switch risk {
        case .standard: return .secondary
        case .elevated: return .orange
        case .dangerous: return .red
        }
    }

    private func choose(_ option: PermissionOption) {
        guard option.id != capability.selected else { return }
        if option.risk == .dangerous {
            pendingDangerousOption = option
        } else {
            onSelect(option.id)
        }
    }
}
