import SwiftUI
import WorkbenchCore

@main struct GoalHeaderPreview: App {
    var body: some Scene {
        WindowGroup("Perch · 目标栏预览") {
            GoalPreview().frame(minWidth: 420, minHeight: 480)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }.defaultSize(width: 860, height: 650)
    }
}

private struct GoalPreview: View {
    @State private var status = "active"
    @State private var running = true
    @State private var offline = false
    @State private var longGoal = false
    @State private var dark = false
    @State private var removed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话阅读体验优化").font(.headline)
                Spacer()
                Text("Perch 项目").foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            if !removed {
                GoalHeaderBar(goal: .init(objective: objective, status: status, turnsUsed: 12, tokensUsed: 48320),
                              isRunning: running, isStale: offline, controlsEnabled: !offline,
                              onControl: { action in
                                  if action == "cancel" { removed = true }
                                  else { status = action == "pause" ? "paused" : "active" }
                              })
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("正文仍是阅读重心").font(.title2.weight(.semibold))
                    Text("目标固定在会话标题下方。阅读历史消息或补充指令时，都能看到这段任务要完成什么。")
                    Text("工具记录与思考过程按需展开，目标的轮数和 Token 用量也收进详情。默认界面只保留有用的信息。")
                    Label("查看处理过程", systemImage: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: 640, alignment: .leading).padding(32)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 24) {
                Text("补充下一步指令…").foregroundStyle(.secondary)
                HStack { Text("Kimi  ·  当前权限").font(.caption); Spacer(); Image(systemName: "arrow.up.circle.fill") }
            }.padding(16).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 32).padding(.bottom, 20)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { previewControls }
                VStack(alignment: .leading, spacing: 8) { previewControls }
            }.padding(12).background(.quaternary.opacity(0.2))
        }.background(WorkbenchTheme.contentBackground).preferredColorScheme(dark ? .dark : .light)
    }
    @ViewBuilder private var previewControls: some View {
        Text("交互示例").font(.caption).foregroundStyle(.secondary)
        Picker("状态", selection: $status) {
            Text("进行中").tag("active"); Text("已暂停").tag("paused")
            Text("需处理").tag("blocked"); Text("已完成").tag("complete")
        }.frame(width: 130).onChange(of: status) { _, value in if value == "complete" { running = false } }
        Toggle("当前轮执行", isOn: $running)
        Toggle("离线", isOn: $offline)
        Toggle("长目标", isOn: $longGoal)
        Toggle("深色", isOn: $dark)
        if removed { Button("恢复示例目标") { removed = false } }
    }
    private var objective: String {
        let summary = "完成 Perch 会话阅读体验优化，让正文清晰、工具过程按需展开，并在验收后提交 PR。"
        return longGoal ? summary + "\n\n" + (1...12).map { "\($0). 检查目标栏在宽窄窗口中的可读性，保留完整目标和明确的续跑操作。" }.joined(separator: "\n") : summary
    }
}
