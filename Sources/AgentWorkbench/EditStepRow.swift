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
            ProcessStatusDot(status: tool.status)
            if tool.status != .succeeded && tool.status != .running {
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

