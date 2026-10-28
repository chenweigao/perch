import SwiftUI
import Observation
import WorkbenchCore

@MainActor @Observable
final class DeliveryRefreshState {
    var loading = false
    var error: String?
    private var requestID: UUID?
    func fetch(_ record: DeliveryRecord, host: SSHHost) async -> PullRequestSnapshot? {
        let id = UUID(); requestID = id; loading = true; error = nil
        defer { if requestID == id { loading = false } }
        do {
            let command = try PullRequestSnapshot.command(directory: record.project.directory, url: record.pullRequest)
            let reader = RemoteReader(local: host.isLocal)
            let response = await withTaskCancellationHandler {
                await reader.run(command: command, destination: host.destination)
            } onCancel: { reader.terminate() }
            try Task.checkCancellation()
            let snapshot = try PullRequestSnapshot.parse(response.get())
            guard requestID == id else { return nil }; return snapshot
        } catch {
            if !Task.isCancelled && requestID == id { self.error = error.localizedDescription }
            return nil
        }
    }
}

struct DeliveryEditor: View {
    let model: WorkbenchModel
    let initial: DeliveryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var record: DeliveryRecord
    @State private var refresh = DeliveryRefreshState()
    @State private var refreshRequest: DeliveryRecord?
    @State private var refreshToken = UUID()
    init(model: WorkbenchModel, initial: DeliveryRecord) {
        self.model = model; self.initial = initial; _record = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("交付与验收").font(.title2)
            Form {
                TextField("交付名称", text: $record.title)
                TextField("验证对应的完整提交 SHA", text: $record.revision)
                Picker("验证结果", selection: $record.validation) {
                    ForEach(EvidenceState.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("验证记录、命令、报告路径", text: $record.evidence, axis: .vertical).lineLimit(3...6)
                Picker("来源会话", selection: $record.source) {
                    Text("无来源会话").tag(SessionReference?.none)
                    ForEach(model.projectSessions(record.project)) { Text($0.title).tag(Optional($0.reference)) }
                }
                TextField("GitHub PR 地址", text: $record.pullRequest)
                Button(refresh.loading ? "正在读取…" : "刷新 PR 与 CI") { refreshRequest = record; refreshToken = UUID() }
                    .disabled(refresh.loading || record.pullRequest.isEmpty)
                Text("使用项目所在机器已登录的 gh；刷新只读取状态。").font(.subheadline).foregroundStyle(.secondary)
                if let snapshot = record.snapshot {
                    Text("PR 状态：\(snapshot.state) · \(snapshot.ciSummary)")
                    Text("HEAD \(snapshot.head)").font(.subheadline.monospaced()).textSelection(.enabled)
                    Text("读取于 \(Date(timeIntervalSince1970: snapshot.fetchedAt).formatted())").font(.subheadline).foregroundStyle(.secondary)
                    if !record.evidenceMatchesHead {
                        Label("验证记录尚未对应当前 PR HEAD", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    ForEach(Array(snapshot.checks.enumerated()), id: \.offset) { _, check in
                        LabeledContent(check.name, value: check.state).font(.subheadline)
                    }
                }
                if let error = refresh.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                Toggle("我已完成验收", isOn: Binding(get: { record.acceptanceCurrent }, set: {
                    record.accepted = $0; record.acceptedRevision = $0 ? record.revision : nil
                })).disabled(record.revision.isEmpty || (record.snapshot != nil && !record.evidenceMatchesHead))
                Text("人工验收、测试结果、PR/CI 分别记录；回复结束不会改变这些状态。").font(.subheadline).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { record.updatedAt = Date().timeIntervalSince1970; model.saveDelivery(record); dismiss() }
                    .disabled(record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 720)
            .onChange(of: record.revision) { _, _ in record.accepted = false }
            .onChange(of: record.evidence) { _, _ in record.accepted = false }
            .onChange(of: record.validation) { _, _ in record.accepted = false }
            .onChange(of: record.pullRequest) { _, _ in record.snapshot = nil; record.accepted = false }
            .task(id: refreshToken) {
                guard let input = refreshRequest else { return }
                guard let host = model.connections.first(where: { $0.id == input.project.hostID })?.host else {
                    refresh.error = L("项目所在环境已移除，无法读取 PR 状态。"); return
                }
                if let result = await refresh.fetch(input, host: host), !Task.isCancelled, record.pullRequest == input.pullRequest {
                    record.snapshot = result
                }
            }
    }
}
