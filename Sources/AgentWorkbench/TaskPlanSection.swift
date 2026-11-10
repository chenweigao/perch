import SwiftUI
import WorkbenchCore

/// Plan visibility belongs to the session, not the mounted inspector page.
struct TaskPlanSection: View {
    let controller: TaskContextWindowController
    let source: SessionReference
    let todos: [ConversationTodo]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @UILocalization private var L

    private var expanded: Bool {
        controller.planExpansion[source] ?? todos.contains { $0.status != .done }
    }

    var body: some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        controller.planExpansion[source] = !expanded
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(WorkbenchTheme.quiet).accessibilityHidden(true)
                        Text("计划").font(.system(size: WorkbenchTheme.Typography.caption, weight: .medium))
                            .foregroundStyle(WorkbenchTheme.quiet)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(todos.filter { $0.status == .done }.count) / \(todos.count)")
                            .font(.system(size: WorkbenchTheme.Typography.caption))
                            .monospacedDigit().foregroundStyle(WorkbenchTheme.quiet)
                    }.frame(minHeight: 30).contentShape(Rectangle())
                }.buttonStyle(TaskContextRowStyle())
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("task-context-plan-toggle")
                if expanded {
                    ForEach(todos) { todo in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: todo.status == .done ? "checkmark.circle"
                                  : todo.status == .inProgress ? "circle.inset.filled" : "circle")
                                .foregroundStyle(todo.status == .inProgress ? WorkbenchTheme.accent : WorkbenchTheme.quiet)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(todo.title).fontWeight(todo.status == .inProgress ? .medium : .regular)
                                    .foregroundStyle(todo.status == .done ? WorkbenchTheme.quiet : Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if todo.status == .inProgress {
                                    Text(verbatim: L("In progress"))
                                        .font(.system(size: WorkbenchTheme.Typography.caption))
                                        .foregroundStyle(WorkbenchTheme.quiet)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.vertical, 6)
                            .background(todo.status == .inProgress ? WorkbenchTheme.Fill.surface : Color.clear,
                                        in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row, style: .continuous))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(verbatim: "\(state(todo.status)): \(todo.title)"))
                            .accessibilityIdentifier("task-context-plan-step-\(todo.id)")
                    }
                }
            }.font(.system(size: WorkbenchTheme.Typography.body))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-context-plan")
        }
    }

    private func state(_ status: ConversationTodo.Status) -> String {
        switch status {
        case .done: return L("Completed")
        case .inProgress: return L("In progress")
        case .pending: return L("Pending")
        }
    }
}
