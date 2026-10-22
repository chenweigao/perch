import SwiftUI
import Observation
import WorkbenchCore

private actor HistorySearchWorker {
    func matches(_ messages: [KimiMessage], query: String) -> [ConversationSearchHit] {
        ConversationSearch().hits(in: messages, query: query, running: false).hits
    }
}

@MainActor @Observable
final class WorkspaceSearchState {
    struct Hit: Identifiable {
        let session: WorkspaceSession
        let excerpt: String
        let entryID: String
        var id: String { session.id + ":" + entryID }
    }
    var hits: [Hit] = []
    var files: ProjectFileSearchResult?
    var progress = ""
    var errors: [String] = []
    var loading = false
    private var generation = UUID()
    private let worker = HistorySearchWorker()
    func reset() { generation = UUID(); loading = false; hits = []; files = nil; errors = []; progress = "" }
    func history(query: String, sessions: [WorkspaceSession], model: WorkbenchModel) async {
        let token = UUID(); generation = token; loading = true; hits = []; errors = []; progress = ""
        defer { if generation == token { loading = false } }
        var partial = 0
        for (index, session) in sessions.enumerated() {
            guard !Task.isCancelled, generation == token else { return }
            do {
                guard let agents = model.agentConnections(for: session.reference.hostID) else { continue }
                let window: HistorySearchWindow
                if session.reference.kind == .kimi { window = try await agents.kimi.searchHistory(for: session.reference.terminalID) }
                else { window = try await agents.native.searchHistory(for: session.reference.terminalID) }
                guard !Task.isCancelled, generation == token else { return }
                if !window.complete { partial += 1 }
                let matches = await worker.matches(window.messages, query: query)
                guard !Task.isCancelled, generation == token else { return }
                var seen = Set<String>()
                hits += matches.filter { seen.insert($0.entryID).inserted }.prefix(max(0, 500 - hits.count)).map {
                    Hit(session: session, excerpt: $0.excerpt, entryID: $0.entryID)
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                errors.append("\(session.title)：\(error.localizedDescription)")
            }
            progress = L("已检查 \(index + 1) / \(sessions.count) 个在线会话 · \(partial) 个仅覆盖最近 5000 条消息")
            if hits.count >= 500 { progress += L(" · 已达到 500 条结果上限"); break }
        }
        if sessions.isEmpty { progress = L("没有可搜索的在线 Agent 会话") }
    }
    func fileSearch(query: String, location: SidebarProjectLocation, host: SSHHost) async {
        let token = UUID(); generation = token; loading = true; files = nil; errors = []
        defer { if generation == token { loading = false } }
        let reader = RemoteReader(local: host.isLocal)
        let response = await withTaskCancellationHandler {
            await reader.run(command: ProjectFileSearchResult.command(directory: location.directory, query: query), destination: host.destination)
        } onCancel: { reader.terminate() }
        guard !Task.isCancelled, generation == token else { return }
        do { files = try JSONDecoder().decode(ProjectFileSearchResult.self, from: response.get()) }
        catch { errors = [error.localizedDescription] }
    }
}

struct UnifiedSearchView: View {
    @Bindable var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope = "会话"
    @State private var projectID = ""
    @State private var state = WorkspaceSearchState()
    @State private var request: Request?
    @State private var filePreview: GroupOutcome?
    @State private var filePreviewLine: Int?
    struct Request: Equatable {
        let id = UUID(); let query: String; let scope: String; let location: SidebarProjectLocation?; let sessions: [WorkspaceSession]
    }
    private var location: SidebarProjectLocation? { model.workbenchProjects.first { $0.id == projectID }?.location }
    private var scopedSessions: [WorkspaceSession] { location.map { model.projectSessions($0) } ?? model.allSessions }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索会话、历史、成果或文件", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button(state.loading ? "取消" : "搜索") { if state.loading { request = nil; state.reset() } else { search() } }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("范围", selection: $scope) {
                ForEach(["会话", "历史", "成果", "文件"], id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
            }.pickerStyle(.segmented)
            Picker("项目", selection: $projectID) {
                Text("全部项目").tag("")
                ForEach(model.workbenchProjects) { project in
                    if let location = project.location { Text("\(project.title) · \(location.hostName)").tag(project.id) }
                }
            }
            if scope == "历史" { Text("显式读取在线会话历史，每个会话最多 5000 条消息；搜索不会切换当前会话。").font(.caption).foregroundStyle(.secondary) }
            if scope == "文件" { Text("选择项目后搜索文件名与正文。最多检查 1000 个文本文件 / 25 MiB，每个文件最多 3 处匹配；跳过构建目录、符号链接和大于 1 MiB 的文件。").font(.caption).foregroundStyle(.secondary) }
            if let request, ["历史", "文件"].contains(scope) { Text("检索词：\(request.query)").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { results }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.loading { ProgressView().controlSize(.small) }
            if !state.progress.isEmpty && scope == "历史" { Text(state.progress).font(.caption).foregroundStyle(.secondary) }
            if !state.errors.isEmpty { DisclosureGroup("\(state.errors.count) 项未能读取") { ForEach(state.errors, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } } }
        }.padding(24).frame(width: 740, height: 620)
            .task(id: request?.id) {
                guard let request else { return }
                if request.scope == "历史" {
                    await state.history(query: request.query, sessions: request.sessions.filter { $0.online && !$0.archived && $0.reference.kind != .terminal }, model: model)
                } else if request.scope == "文件", let location = request.location,
                          let host = model.connections.first(where: { $0.id == location.hostID })?.host {
                    await state.fileSearch(query: request.query, location: location, host: host)
                } else if request.scope == "文件" {
                    state.errors = [L("项目所在环境已移除，无法读取文件。")]
                }
            }
            .onChange(of: scope) { _, _ in request = nil; state.reset() }
            .onChange(of: projectID) { _, _ in request = nil; state.reset() }
            .sheet(item: $filePreview) { outcome in OutcomePreviewSheet(model: model, outcome: outcome, location: scope == "文件" ? request?.location : nil, line: scope == "文件" ? filePreviewLine : nil) }
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { request = nil; state.reset(); return }
        state.reset()
        if scope == "文件" && location == nil { state.errors = [L("请先选择文件所在的项目。")]; return }
        request = Request(query: text, scope: scope, location: location, sessions: scopedSessions)
    }
    @ViewBuilder private var results: some View {
        switch scope {
        case "会话":
            ForEach(scopedSessions.filter { $0.matchesSearch(query) }) { item in
                Button { model.open(item); dismiss() } label: {
                    VStack(alignment: .leading) { Text(item.title); Text("\(item.hostName) · \(item.directory)").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).disabled(!item.online || item.archived)
            }
        case "历史":
            ForEach(state.hits) { hit in
                Button {
                    model.open(hit.session); model.showConversationFind = true
                    model.workspaceSearchQuery = request?.query ?? query
                    model.workspaceSearchEntryID = hit.entryID
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(hit.session.title).fontWeight(.medium); Text(hit.excerpt).lineLimit(3).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
                Divider()
            }
        case "成果":
            let references = Set(scopedSessions.map(\.reference))
            ForEach(model.workspace.groups) { group in
                ForEach(group.outcomes.filter { outcome in
                    (projectID.isEmpty || outcome.source.map(references.contains) == true)
                    && (query.isEmpty || "\(outcome.title) \(outcome.detail) \(outcome.link)".localizedStandardContains(query))
                }) { outcome in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.title).fontWeight(.medium)
                        Text("\(group.name) · \(outcome.detail)").font(.caption).lineLimit(3)
                        if !outcome.link.isEmpty {
                            Button("打开成果") { if let url = outcome.webURL { NSWorkspace.shared.open(url) } else { filePreview = outcome } }
                        }
                    }
                }
            }
        case "文件":
            if let result = state.files {
                Text("已检查 \(result.inspected) 个文件 · 跳过 \(result.skipped) 个").font(.caption).foregroundStyle(.secondary)
                if result.limited { Text("已达搜索上限").font(.caption).foregroundStyle(.secondary) }
                ForEach(result.hits) { hit in
                    Button {
                        filePreviewLine = hit.line
                        filePreview = GroupOutcome(title: (hit.path as NSString).lastPathComponent, link: hit.path,
                                                   source: request?.sessions.first(where: { $0.reference.hostID == request?.location?.hostID && $0.reference.kind != .terminal })?.reference)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) { Text("\(hit.path):\(hit.line)").font(.caption.monospaced()); Text(hit.excerpt).lineLimit(2) }
                    }.buttonStyle(.plain)
                }
            }
        default: EmptyView()
        }
    }
}
