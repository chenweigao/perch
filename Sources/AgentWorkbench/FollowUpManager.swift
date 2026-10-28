import SwiftUI
import WorkbenchCore

struct FollowUpManager: View {
    @Bindable var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("companion.background") private var background = false
    @State private var target: SessionReference?
    @State private var trigger: FollowUpTrigger = .time
    @State private var due = Date().addingTimeInterval(3600)
    @State private var minutes = 30
    @State private var prompt = ""
    private var item: WorkspaceSession? { model.allSessions.first { $0.reference == target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("长任务托管").font(.title2); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Perch 运行时每 15 秒检查一次。机器离线、会话归档或等待审批时，发送会等待；已有任务仍由原 Agent 执行。")
                .font(.subheadline).foregroundStyle(.secondary)
            Toggle("关闭主窗口后继续在菜单栏运行", isOn: $background)
            Form {
                Picker("会话", selection: $target) {
                    Text("选择会话").tag(SessionReference?.none)
                    ForEach(model.allSessions.filter { !$0.archived && $0.reference.kind != .terminal }) { item in
                        Text("\(item.title) · \(item.hostName)").tag(Optional(item.reference))
                    }
                }
                Picker("触发条件", selection: $trigger) {
                    ForEach(FollowUpTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if trigger == .time { DatePicker("发送时间", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute]) }
                if trigger == .inactivity { Stepper("\(minutes) 分钟没有更新", value: $minutes, in: 5...1440, step: 5) }
                else { TextField("触发后发送的指令", text: $prompt, axis: .vertical).lineLimit(3...6) }
                Button("添加一次性托管") {
                    guard let item else { return }
                    model.addFollowUp(FollowUpRule(session: item, trigger: trigger, dueAt: due, idleMinutes: minutes, prompt: prompt))
                    prompt = ""
                }.disabled(item == nil || (trigger != .inactivity && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.formStyle(.grouped).frame(height: 260)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.workspace.followUps.reversed()) { rule in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(rule.title).fontWeight(.medium); Spacer()
                                if [.pending, .needsReview].contains(rule.status) { Button("取消") { model.cancelFollowUp(rule.id) } }
                            }
                            Text("\(rule.trigger.title) · \(rule.status.title)").foregroundStyle(.secondary)
                            if rule.status == .needsReview {
                                Text("发送时发生中断。请先检查来源会话的发送队列和回复，确认后再手动添加托管。").font(.subheadline).foregroundStyle(.orange)
                            }
                            if rule.trigger == .time { Text(Date(timeIntervalSince1970: rule.dueAt).formatted()).font(.subheadline) }
                            if !rule.prompt.isEmpty { Text(rule.prompt).lineLimit(3).textSelection(.enabled) }
                            if let item = model.allSessions.first(where: { $0.reference == rule.session }) {
                                Button("打开来源会话") { dismiss(); model.open(item) }.disabled(!item.online).buttonStyle(QuietLinkStyle())
                            }
                        }
                        Divider()
                    }
                }.font(.system(size: 12))
            }
        }.padding(24).frame(width: 660, height: 700)
            .onAppear { target = model.selectedReference; model.followUpNotices = [] }
    }
}
