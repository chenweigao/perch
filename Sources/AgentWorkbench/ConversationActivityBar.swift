import AppKit
import SwiftUI
import WorkbenchCore

/// AppKit animates the system spinner without invalidating the transcript graph.
struct ConversationBusyIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion { Image(systemName: "hourglass").font(.system(size: 12)).foregroundStyle(.secondary) }
            else { BusySpinner() }
        }.frame(width: 16, height: 16).accessibilityHidden(true)
    }
}

private struct BusySpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = .small
        view.isIndeterminate = true
        view.startAnimation(nil)
        return view
    }
    func updateNSView(_ view: NSProgressIndicator, context: Context) {}
    static func dismantleNSView(_ view: NSProgressIndicator, coordinator: ()) { view.stopAnimation(nil) }
}

/// Kept outside the scrolling transcript, immediately above the composer.
struct ConversationActivityBar: View {
    let messages: [KimiMessage]
    let isRunning: Bool
    var isThinking = false
    var runningToolCount = 0
    @State private var expanded = false
    @State private var pointerAnchor: CGRect?
    private var todos: [ConversationTodo] { ConversationTodo.floating(in: messages, isRunning: isRunning) }
    private var status: String {
        if isThinking { return "正在思考" }
        return runningToolCount > 0 ? "正在处理 · \(runningToolCount) 项操作" : "正在处理"
    }
    var body: some View {
        let items = todos
        if !items.isEmpty || isRunning {
            HStack(spacing: 9) {
                if isRunning { ConversationBusyIndicator() }
                else { Image(systemName: "checklist").font(.system(size: 12)).foregroundStyle(.secondary) }
                if items.isEmpty {
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Button { pointerAnchor = nil; expanded.toggle() } label: {
                        HStack(spacing: 9) {
                            Text("\(items.filter { $0.status == .done }.count)/\(items.count)")
                                .monospacedDigit().foregroundStyle(.secondary)
                            if !isRunning { Text("未完成").foregroundStyle(.secondary) }
                            Text(items.first { $0.status == .inProgress }?.title ?? items.first { $0.status == .pending }?.title ?? "计划已完成")
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                        }.font(.system(size: 12)).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("查看任务清单")
                        .highPriorityGesture(SpatialTapGesture().onEnded { value in
                            pointerAnchor = CGRect(x: value.location.x, y: value.location.y, width: 1, height: 1)
                            expanded.toggle()
                        })
                        .popover(isPresented: $expanded, attachmentAnchor: .rect(pointerAnchor.map { .rect($0) } ?? .bounds), arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("任务清单").font(.system(size: 13, weight: .semibold))
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 13) {
                                        ForEach(items) { item in
                                            HStack(alignment: .top, spacing: 9) {
                                                Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                                    .foregroundStyle(item.status == .inProgress ? Color.accentColor : Color.secondary)
                                                Text(item.title).foregroundStyle(item.status == .done ? .secondary : .primary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }.font(.system(size: 12)).accessibilityElement(children: .combine)
                                                .accessibilityLabel("\(item.status == .done ? "已完成" : item.status == .inProgress ? "进行中" : "待办")：\(item.title)")
                                        }
                                    }.padding(.vertical, 2)
                                }.frame(maxHeight: 260)
                            }.padding(16).frame(width: 330)
                        }
                }
            }.padding(.horizontal, 13).frame(height: 36)
                .workbenchFloatingSurface()
        }
    }
}
