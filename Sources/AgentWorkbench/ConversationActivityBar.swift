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

/// Kept outside the transcript; only the clock subview refreshes every second.
struct ConversationActivityBar: View {
    let activity: ConversationActivity
    let isRunning: Bool
    var turnID: String = ""
    var online = true
    var pendingCount = 0
    var onReview: () -> Void = {}
    var onReconnect: () -> Void = {}
    @State private var expanded = false
    @State private var observedSince: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if activity.isVisible {
                HStack(spacing: 10) {
                    Button { expanded.toggle() } label: {
                        HStack(spacing: 9) {
                            if activity.animates { ConversationBusyIndicator() }
                            else { Image(systemName: activity.symbol).frame(width: 16) }
                            Text(activity.title).lineLimit(1).truncationMode(.tail)
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity.title)
                            Spacer(minLength: 4)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { counts; clock }
                                counts
                                EmptyView()
                            }.foregroundStyle(.secondary).layoutPriority(-1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Task activity")
                        .accessibilityValue(activity.title).help("Show task plan and current activity")
                        .popover(isPresented: $expanded, arrowEdge: .top) { details }
                    if !online {
                        Button("Reconnect", action: onReconnect).buttonStyle(.borderless)
                    } else if pendingCount > 0 {
                        Button("Review") { onReview() }.buttonStyle(.borderless)
                    }
                }.font(.system(size: 12))
                    .foregroundStyle(activity.needsAttention ? Color.orange : Color.secondary)
                    .padding(.horizontal, 13).frame(height: 36).workbenchFloatingSurface()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: activity.isVisible)
        .onChange(of: isRunning, initial: true) { _, running in observedSince = running ? Date() : nil }
        .onChange(of: turnID) { _, _ in observedSince = isRunning ? Date() : nil }
    }

    @ViewBuilder private var counts: some View {
        HStack(spacing: 10) {
            if !activity.todos.isEmpty { Text("\(activity.completedSteps)/\(activity.todos.count) steps") }
            if !activity.activeTools.isEmpty { Text("\(activity.activeTools.count) \(activity.activeTools.count == 1 ? "tool" : "tools")") }
        }.fixedSize().monospacedDigit()
    }
    @ViewBuilder private var clock: some View {
        if online, isRunning, let observedSince { ActivityObservedClock(since: observedSince) }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Task plan", systemImage: "checklist").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !activity.todos.isEmpty {
                    Text("\(activity.completedSteps)/\(activity.todos.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                Button { expanded = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close activity details")
            }
            if !online {
                Text("Updates are disconnected. Tool states below are the last known states.").foregroundStyle(.secondary)
                Button("Reconnect") { expanded = false; onReconnect() }
            } else if pendingCount > 0 {
                Text("\(pendingCount) pending \(pendingCount == 1 ? "request" : "requests") in this conversation.").foregroundStyle(.secondary)
                Button("Review in conversation") { expanded = false; onReview() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !activity.todos.isEmpty {
                        ForEach(activity.todos) { item in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                                    .foregroundStyle(item.status == .inProgress ? Color.accentColor : Color.secondary)
                                Text(item.title).fontWeight(item.status == .inProgress ? .medium : .regular)
                                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                            }.accessibilityElement(children: .combine)
                                .accessibilityLabel("\(item.status == .done ? "Completed" : item.status == .inProgress ? "In progress" : "Pending"): \(item.title)")
                        }
                    } else {
                        Text("No plan reported yet.").foregroundStyle(.secondary)
                    }
                    if !activity.attentionTools.isEmpty {
                        Divider()
                        Text("Needs attention").fontWeight(.semibold).foregroundStyle(.orange)
                        ForEach(activity.attentionTools) { tool in ActivityToolDetails(tool: tool) }
                    }
                    if !activity.activeTools.isEmpty {
                        Divider()
                        Text("Current activity").fontWeight(.semibold)
                        ForEach(activity.activeTools) { tool in ActivityToolDetails(tool: tool) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 300)
        }.font(.system(size: 12)).padding(16).frame(width: 390)
    }
}

private struct ActivityObservedClock: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text("Observed \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                .monospacedDigit().fixedSize()
        }.help("Time observed in this view, including waits. Earlier runtime is unknown.")
    }
}

private struct ActivityToolDetails: View {
    let tool: VisibleTool
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = tool.input { Text("Input").fontWeight(.medium); Text(input.display).textSelection(.enabled) }
                    if let progress = tool.progress { Text("Latest update").fontWeight(.medium); Text(progress.display).textSelection(.enabled) }
                    if let output = tool.output { Text("Result").fontWeight(.medium); Text(output.display).textSelection(.enabled) }
                }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tool.name).fontWeight(.medium)
                    Spacer()
                    Text(tool.hasCall ? ConversationActivity.status(of: tool) : "Call record missing")
                        .foregroundStyle(tool.staysVisible && tool.status != .running ? Color.orange : Color.secondary)
                }
                let summary = ConversationActivity.summary(of: tool)
                if summary != tool.name { Text(summary).lineLimit(2).foregroundStyle(.secondary) }
                if let progress = tool.progress { Text(progress.display).lineLimit(2).foregroundStyle(.secondary) }
            }
        }
    }
}
