import SwiftUI
import WorkbenchCore

struct TaskGroupOverview: View {
    @UILocalization private var L
    @Bindable var model: WorkbenchModel
    @State private var query = ""
    var body: some View {
        if model.selectedGroup == nil {
            let summaries = model.groupSummaries
            let active = summaries.filter { $0.group.stage == .active }
            let visible = model.showAllTaskGroups ? summaries.filter {
                query.isEmpty || "\($0.group.name) \($0.group.goal) \($0.group.nextStep)".localizedStandardContains(query)
            } : Array(active.prefix(5))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.showAllTaskGroups ? "全部任务组" : "正在推进的任务组")
                        .font(.system(size: 13, weight: .medium)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(model.showAllTaskGroups ? "收起任务组" : "全部任务组") {
                        model.showAllTaskGroups.toggle()
                    }.buttonStyle(.link)
                    Button("新建任务组") { model.editGroup() }.buttonStyle(.link)
                }
                if model.showAllTaskGroups {
                    TextField("搜索任务组", text: $query).textFieldStyle(.roundedBorder)
                }
                if visible.isEmpty {
                    Text(summaries.isEmpty ? "把共同目标和相关会话放在一起，也可以直接开始会话。" :
                         model.showAllTaskGroups ? "没有匹配的任务组" : "暂无进行中的任务组")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { summary in
                    Button { model.showHome(groupID: summary.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                if summary.group.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
                                Text(summary.group.name).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                Spacer()
                                Text(L(key: summary.group.stage.title)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if !summary.group.nextStep.isEmpty {
                                Text("下一步：\(summary.group.nextStep)").lineLimit(2)
                            } else if !summary.group.goal.isEmpty {
                                Text(summary.group.goal).lineLimit(2).foregroundStyle(.secondary)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { activity(summary) }
                                VStack(alignment: .leading, spacing: 5) { activity(summary) }
                            }
                            if let outcome = summary.group.outcomes.last {
                                Text("最近成果：\(outcome.title)").lineLimit(1).foregroundStyle(.secondary)
                            } else if let result = summary.latestResult {
                                Text("待查看结果：\(result.title)").lineLimit(1).foregroundStyle(.secondary)
                            }
                        }.font(.system(size: 12)).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("workbench.group.\(summary.id)")
                        .contextMenu {
                            Button(summary.group.isPinned ? "取消置顶" : "置顶任务组") { model.toggleGroupPin(summary.group) }
                            Button("编辑任务组") { model.editGroup(summary.group) }
                        }
                    Divider()
                }
                if !model.showAllTaskGroups && active.count > visible.count {
                    Button("查看全部任务组") { model.showAllTaskGroups = true }.buttonStyle(.link)
                }
            }.font(.system(size: 12))
        }
    }
    @ViewBuilder private func activity(_ value: TaskGroupSummary) -> some View {
        if value.attentionCount > 0 { Text("\(value.attentionCount) 项等你处理").foregroundStyle(.orange) }
        if value.reviewCount > 0 { Text("\(value.reviewCount) 项结果待查看").foregroundStyle(.secondary) }
        if value.runningCount > 0 { Text("\(value.runningCount) 项运行中").foregroundStyle(.secondary) }
        if value.unsyncedCount > 0 { Text("\(value.unsyncedCount) 项状态未同步").foregroundStyle(.secondary) }
        if value.attentionCount == 0 && value.reviewCount == 0 && value.runningCount == 0 && value.unsyncedCount == 0 {
            Text("当前没有待处理事项").foregroundStyle(.secondary)
        }
    }
}
