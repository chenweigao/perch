import SwiftUI
import WorkbenchCore

struct GoalHeaderBar: View {
    @UILocalization private var L
    let goal: KimiGoal
    let isRunning: Bool
    let isStale: Bool
    let controlsEnabled: Bool
    var onRefresh: () -> Void = {}
    let onControl: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "flag").foregroundStyle(WorkbenchTheme.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("目标").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(goal.objective).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary).lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 3)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L(expanded ? "收起目标详情" : "展开目标详情"))
                    .accessibilityValue(goal.objective)
                    .accessibilityIdentifier("goal-disclosure")
                VStack(alignment: .trailing, spacing: 8) {
                    status
                    HStack(spacing: 8) {
                        if let control = goal.continuationControl {
                            Button(action: { onControl(control) }) {
                                Label(control == "pause" ? L("暂停续跑") : L("继续目标"),
                                      systemImage: control == "pause" ? "pause" : "play")
                            }.buttonStyle(.borderless).foregroundStyle(WorkbenchTheme.accent)
                                .help(control == "pause" ? L("暂停后不再自动续跑；当前这一轮仍可完成。") : L("继续按目标执行，保持当前权限设置。"))
                                .accessibilityIdentifier("goal-continuation")
                        }
                        Menu {
                            Button("取消目标", role: .destructive) { onControl("cancel") }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 20, height: 20)
                        }.menuIndicator(.hidden).menuStyle(.borderlessButton)
                            .fixedSize().help("目标操作")
                            .accessibilityLabel(L("目标操作"))
                    }.disabled(!controlsEnabled || isStale)
                }.font(.system(size: 11)).fixedSize(horizontal: true, vertical: false)
            }
            if expanded {
                ScrollView {
                    Text(goal.objective).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("goal-full-objective")
                HStack(spacing: 16) {
                    Label(L("已用 \(goal.turnsUsed) 轮"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    Text(L("已用 \(goal.tokensUsed) Token"))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text("暂停或取消目标不会中断当前这一轮；如需中断，请使用输入区的停止按钮。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.contentBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal-header")
    }

    @ViewBuilder private var status: some View {
        if isStale {
            Button(action: onRefresh) {
                Label("待同步", systemImage: "arrow.clockwise")
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(!controlsEnabled).help("重新同步目标")
        } else {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.mini).accessibilityLabel(L("当前一轮正在执行"))
                }
                switch goal.status {
                case "active":
                    if !isRunning { Label("待续跑", systemImage: "clock").foregroundStyle(.secondary) }
                case "paused": Label("已暂停", systemImage: "pause.circle").foregroundStyle(.secondary)
                case "complete": Label("已完成", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                case "blocked": Label("需处理", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                default: Label("状态未知", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }
}
