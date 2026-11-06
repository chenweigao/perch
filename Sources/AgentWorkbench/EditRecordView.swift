import SwiftUI
import WorkbenchCore

struct EditStepRow: View {
    let tool: VisibleTool
    let messageID: String
    @Binding var expanded: Bool
    @Environment(\.conversationActionContext) private var context

    var body: some View {
        let stat = ConversationEditRecord.stat(tool)
        HStack(spacing: 6) {
            DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                Text("编辑").font(.system(size: ReplyStyle.Process.labelSize))
            }.disclosureGroupStyle(ProcessDisclosureStyle()).fixedSize()
            if let path = ToolPresentation.path(tool) {
                Button { openFile(path) } label: {
                    Text(verbatim: ToolPresentation.target(tool)).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).help(Text(verbatim: path))
            } else {
                Text(ToolPresentation.target(tool)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if tool.status != .succeeded {
                Text(ConversationActivity.status(of: tool, exitCode: tool.exitCodeReport))
                    .font(.system(size: ReplyStyle.captionSize))
                    .foregroundStyle(tool.status == .awaitingApproval ? Color.orange : WorkbenchTheme.quiet)
                    .fixedSize()
            }
            Button { context?.post(.showEdit(tool, messageID: messageID)) } label: {
                Group {
                    if let stat {
                        if tool.status == .succeeded { EditStatText(stat: stat) }
                        else { Text(verbatim: "+\(stat.additions) −\(stat.deletions)").monospacedDigit() }
                    } else { Text("编辑记录") }
                }.font(.system(size: ReplyStyle.captionSize)).padding(.horizontal, 4).frame(height: 22).contentShape(Rectangle())
            }.buttonStyle(WorkbenchDisclosureButtonStyle())
                .disabled(context == nil).fixedSize()
                .help("查看本步编辑记录")
                .accessibilityLabel("查看本步编辑记录")
                .accessibilityIdentifier("edit-step:" + tool.id)
                .accessibilityValue(Text(verbatim: stat.map { "+\($0.additions) −\($0.deletions)" } ?? ""))
        }.font(.system(size: ReplyStyle.Process.labelSize)).foregroundStyle(WorkbenchTheme.quiet)
    }

    private func openFile(_ path: String) {
        var url = URLComponents(); url.scheme = "perch-file"
        url.queryItems = [URLQueryItem(name: "path", value: path)]
        if let target = url.url { NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: target) }
    }
}

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
