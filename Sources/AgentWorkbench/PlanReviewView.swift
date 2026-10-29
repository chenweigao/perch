import SwiftUI
import Observation
import WorkbenchCore

@MainActor @Observable final class PlanReviewState {
    var feedback = ""
    var editing = false
    private(set) var submitting = false
    private(set) var notice: String?
    private(set) var displayed: NativePlanReview?
    private var latest: NativePlanReview?
    private var settledRevision: String?
    var canDecide: Bool { !submitting && displayed != nil && displayed == latest && displayed?.revision != settledRevision }

    func update(_ plan: NativePlanReview?) {
        latest = plan
        guard !submitting else { return }
        if let previous = displayed, let plan, previous.revision != plan.revision, !feedback.isEmpty {
            notice = L("计划已更新，修改意见已保留，请核对后再提交。")
        }
        if plan != nil || notice == nil { displayed = plan }
    }
    func dismissNotice() { notice = nil; displayed = latest }
    func submit(_ decision: String, send: (NativePlanReview, String, String) async throws -> Void) async {
        guard canDecide, let plan = displayed,
              decision != "approve" || plan.complete,
              decision != "request_changes" || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submitting = true; notice = nil
        do {
            try await send(plan, decision, feedback)
            if decision == "approve" || decision == "request_changes" {
                settledRevision = plan.revision
                if latest == nil || latest?.revision == plan.revision { feedback = ""; editing = false }
            }
            displayed = latest
        } catch {
            notice = error.localizedDescription
            displayed = latest ?? plan
        }
        submitting = false
    }
}

struct NativePlanReviewDock: View {
    let connection: NativeAgentConnection
    let sessionID: String
    @State private var state = PlanReviewState()
    private var pending: NativePlanReview? {
        guard connection.snapshot?.id == sessionID else { return nil }
        return connection.snapshot?.interactions.compactMap(NativePlanReview.init).first
    }
    var body: some View {
        PlanReviewPanel(state: state, online: connection.online) { plan, decision, feedback in
            guard connection.selectedID == sessionID, connection.snapshot?.id == sessionID,
                  connection.snapshot?.interactions.compactMap(NativePlanReview.init).contains(plan) == true else {
                throw WorkbenchError(L("计划已变化或会话已切换，请重新查看。"))
            }
            try await connection.action(sessionID, "answer", plan.answer(decision, feedback: feedback))
        }.onChange(of: pending, initial: true) { _, value in state.update(value) }
    }
}

/// The plan's first lines as plain text, without Markdown syntax or blank lines.
/// Equatable, so typing review feedback does not parse the plan again.
private struct PlanPreviewText: View, Equatable {
    let content: String
    var body: some View {
        Text(verbatim: ReplyPlainText.text(from: content).split(whereSeparator: \.isNewline).joined(separator: "\n"))
    }
}

struct PlanReviewPanel: View {
    @Bindable var state: PlanReviewState
    let online: Bool
    let send: (NativePlanReview, String, String) async throws -> Void
    @State private var showPlan = false
    @FocusState private var focused: Bool
    private func submit(_ decision: String) {
        Task { await state.submit(decision, send: send) }
    }
    var body: some View {
        if let plan = state.displayed {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(plan.deferred ? "计划已暂缓" : "审阅计划", systemImage: "doc.text.magnifyingglass").font(.headline)
                    Spacer()
                    if state.submitting { ProgressView().controlSize(.small) }
                }
                Group {
                    if plan.content.isEmpty { Text("尚未收到完整计划，请要求 Agent 补充后再批准。") }
                    else { PlanPreviewText(content: plan.content).equatable() }
                }.font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                HStack {
                    Button("查看完整计划") { showPlan = true }.disabled(plan.content.isEmpty)
                    ReplyCopyButton(text: plan.content, label: "复制计划").disabled(plan.content.isEmpty)
                }
                if plan.changed { Text("计划文件已变化，请重新审阅。").font(.callout).foregroundStyle(.orange) }
                if let notice = state.notice {
                    Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    if !state.canDecide { Button("关闭提示") { state.dismissNotice() } }
                }
                if plan.deferred {
                    Text("Agent 仍在等待，继续审批后再决定。").font(.subheadline).foregroundStyle(.secondary)
                    Button("继续审批") { submit("resume") }.disabled(!state.canDecide || !online)
                } else {
                    Text("批准本次计划，工具权限沿用当前设置。").font(.subheadline).foregroundStyle(.secondary)
                    if state.editing {
                        TextField("填写修改意见", text: $state.feedback, axis: .vertical)
                            .lineLimit(3...8).textFieldStyle(.roundedBorder).focused($focused)
                        HStack {
                            Button("提交修改意见") { submit("request_changes") }
                                .disabled(state.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("返回") { state.editing = false }
                        }.disabled(!state.canDecide || !online)
                    } else {
                        HStack {
                            Button("批准计划") { submit("approve") }.disabled(!plan.complete)
                            Button("提出修改") { state.editing = true; focused = true }
                            Button("稍后审批") { submit("defer") }
                        }.disabled(!state.canDecide || !online)
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchTheme.Fill.surface,
                            in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.card))
                // Enter and Escape have no approval binding; dismissal sends nothing.
                .sheet(isPresented: $showPlan) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("审阅计划").font(.headline); Spacer(); Button("关闭") { showPlan = false }.keyboardShortcut(.cancelAction) }
                        ScrollView { KimiMarkdown(text: plan.content).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    }.padding(WorkbenchTheme.Dialog.padding).frame(minWidth: 480, idealWidth: 680, minHeight: 360, idealHeight: 640)
                }
        }
    }
}
