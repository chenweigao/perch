import SwiftUI
import WorkbenchCore

struct EditRecordInspectorView: View {
    let model: WorkbenchModel
    @State private var wholeTurn = false
    private var record: ConversationEditRecord? {
        guard !model.showDashboard, !model.draftingNewTask,
              let selection = model.taskContextWindow.editRecord,
              selection.source == model.selectedReference else { return nil }
        return selection.record
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("编辑记录").accessibilityIdentifier("edit-record-title").font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                Spacer()
                Button { model.taskContextWindow.embeddedVisible = false } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }.buttonStyle(.borderless).help("收起面板").accessibilityLabel("收起面板")
            }.padding(.horizontal, 20).padding(.top, 12)
            if let record {
                Picker("记录范围", selection: $wholeTurn) {
                    Text("本步编辑记录").tag(false)
                    Text("本轮编辑记录").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 16)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(wholeTurn ? "按调用累加，不等于 Git 净差异。" : "来自该次工具调用的历史记录。")
                            .foregroundStyle(WorkbenchTheme.quiet)
                        if wholeTurn {
                            HStack {
                                Text("已成功调用的累计增删")
                                Spacer()
                                EditStatText(stat: record.appliedTotal)
                            }
                            if !record.hasTurn {
                                Text("当前只载入了部分轮次记录。").foregroundStyle(.orange)
                            }
                        }
                        ForEach(wholeTurn ? record.turn : [record.step]) { tool in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(ToolPresentation.target(tool)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ConversationActivity.status(of: tool, exitCode: tool.exitCodeReport))
                                        .foregroundStyle(tool.status == .awaitingApproval ? Color.orange : WorkbenchTheme.quiet)
                                }
                                if tool.name.lowercased().hasPrefix("write") {
                                    Text("写入内容；调用未提供旧文件，无法计算净删除行数。")
                                        .foregroundStyle(WorkbenchTheme.quiet)
                                }
                                if let diff = ToolInlineDiff.derive(from: tool, maxLines: Int.max) {
                                    ToolInlineDiffCard(diff: diff, applied: tool.status == .succeeded)
                                } else {
                                    Text("该步骤没有可还原的补丁，以下是原始调用记录。")
                                        .foregroundStyle(WorkbenchTheme.quiet)
                                    if let input = tool.input { DisclosureReplyText(text: input.display) }
                                }
                                if tool.status == .failed, let output = tool.output {
                                    DisclosureReplyText(text: output.display)
                                }
                            }
                            Divider()
                        }
                    }.padding(16).textSelection(.enabled)
                }
                Button("查看当前工作区净差异") {
                    model.taskContextWindow.showPage(.changes, model: model)
                }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                Text("从当前会话选择一个编辑步骤。").accessibilityIdentifier("edit-record-empty").foregroundStyle(.secondary).padding(20)
                Spacer()
            }
        }.font(.system(size: WorkbenchTheme.Typography.caption))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: record) { _, _ in wholeTurn = false }
            .onChange(of: model.selectedReference) { _, _ in wholeTurn = false }
    }
}
