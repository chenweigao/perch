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
    @State private var selection: String?
    @FocusState private var focused: Bool
    @State private var state = WorkspaceSearchState()
    @State private var request: Request?
    struct Request: Equatable {
        let id = UUID(); let query: String; let scope: String; let location: SidebarProjectLocation?; let sessions: [WorkspaceSession]
    }
    private struct Result: Identifiable {
        enum Destination { case session(WorkspaceSession), history(WorkspaceSearchState.Hit), outcome(GroupOutcome), file(ProjectFileSearchResult.Hit) }
        let id: String
        let title: String
        let detail: String
        let enabled: Bool
        let destination: Destination
    }
    private var location: SidebarProjectLocation? { model.workbenchProjects.first { $0.id == projectID }?.location }
    private var scopedSessions: [WorkspaceSession] { location.map { model.projectSessions($0) } ?? model.allSessions }
    private func results(sessions: [WorkspaceSession]) -> [Result] {
        switch scope {
        case "会话": return sessions.map {
            Result(id: $0.id, title: $0.title, detail: "\($0.hostName) · \($0.directory)", enabled: $0.online && !$0.archived, destination: .session($0))
        }
        case "历史": return state.hits.map {
            Result(id: $0.id, title: $0.session.title, detail: $0.excerpt, enabled: true, destination: .history($0))
        }
        case "成果":
            let references = Set(scopedSessions.map(\.reference))
            return model.workspace.groups.flatMap { group in
                group.outcomes.filter { outcome in
                    (projectID.isEmpty || outcome.source.map(references.contains) == true)
                    && (query.isEmpty || "\(outcome.title) \(outcome.detail) \(outcome.link)".localizedStandardContains(query))
                }.map { Result(id: "\(group.id):\($0.id)", title: $0.title, detail: "\(group.name) · \($0.detail)", enabled: !$0.link.isEmpty, destination: .outcome($0)) }
            }
        case "文件": return (state.files?.hits ?? []).map {
            Result(id: $0.id, title: "\($0.path):\($0.line)", detail: $0.excerpt, enabled: true, destination: .file($0))
        }
        default: return []
        }
    }
    var body: some View {
        let sessions = scope == "会话" ? scopedSessions.filter { $0.matchesSearch(query) } : []
        let rows = results(sessions: sessions)
        let available = rows.filter(\.enabled)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索会话、历史、成果或文件", text: $query)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submit(rows) }
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { move(1, key: $0, rows: available) }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { move(-1, key: $0, rows: available) }
                    .accessibilityIdentifier("PerchUnifiedSearchField")
                Button(state.loading ? "取消" : "搜索") { if state.loading { cancelSearch() } else { search() } }
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
            if ["历史", "文件"].contains(scope) {
                DisclosureGroup("搜索范围说明") {
                    if scope == "历史" { Text("显式读取在线会话历史，每个会话最多 5000 条消息；搜索不会切换当前会话。") }
                    else { Text("选择项目后搜索文件名与正文。最多检查 1000 个文本文件 / 25 MiB，每个文件最多 3 处匹配；跳过构建目录、符号链接和大于 1 MiB 的文件。") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            Button { open(row) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title).fontWeight(.medium).lineLimit(2)
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .contentShape(Rectangle())
                                    .background(selection == row.id ? Color.accentColor.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: WorkbenchTheme.Radius.row))
                            }.buttonStyle(.plain).disabled(!row.enabled).id(row.id)
                                .accessibilityAddTraits(selection == row.id ? [.isSelected] : [])
                        }
                        if rows.isEmpty && !state.loading { Text("没有找到结果").foregroundStyle(.secondary).padding(24) }
                    }
                }
                .onChange(of: selection) { _, value in if let value { proxy.scrollTo(value) } }
            }
            if state.loading { ProgressView().controlSize(.small) }
            if !state.progress.isEmpty && scope == "历史" { Text(state.progress).font(.caption).foregroundStyle(.secondary) }
            if let result = state.files, scope == "文件" {
                Text("已检查 \(result.inspected) 个文件 · 跳过 \(result.skipped) 个").font(.caption).foregroundStyle(.secondary)
                if result.limited { Text("已达搜索上限").font(.caption).foregroundStyle(.secondary) }
            }
            if !state.errors.isEmpty { DisclosureGroup("\(state.errors.count) 项未能读取") { ForEach(state.errors, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } } }
            Text("↑↓ 选择 · 回车打开 · Esc 关闭").font(.caption).foregroundStyle(.tertiary)
        }.padding(24).frame(width: 740, height: 620)
            .defaultFocus($focused, true)
            .task { focused = true }
            .onChange(of: available.map(\.id), initial: true) { _, ids in
                if selection.map(ids.contains) != true { selection = ids.first }
            }
            #if PERCH_ACCEPTANCE
            .onReceive(NativeAcceptanceProbe.shared.$query) { value in if let value { query = value } }
            .background(NativeDirectoryProbe(query: query, selection: selection, results: sessions.map(\.id)))
            #endif
            .task(id: request?.id) {
                guard let request else { return }
                if request.scope == "历史" {
                    await state.history(query: request.query, sessions: request.sessions.filter { $0.online && !$0.archived && $0.reference.kind != .terminal }, model: model)
                } else if request.scope == "文件", let location = request.location,
                          let host = model.connections.first(where: { $0.id == location.hostID })?.host {
                    await state.fileSearch(query: request.query, location: location, host: host)
                } else if request.scope == "文件" { state.errors = [L("项目所在环境已移除，无法读取文件。")] }
            }
            .onChange(of: scope) { _, _ in cancelSearch(); focused = true }
            .onChange(of: projectID) { _, _ in cancelSearch() }
            .onChange(of: query) { _, _ in
                selection = available.first?.id
                if ["历史", "文件"].contains(scope) { cancelSearch() }
            }
    }
    private func cancelSearch() { request = nil; state.reset(); selection = nil }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelSearch(); return }
        state.reset()
        if scope == "文件" && location == nil { state.errors = [L("请先选择文件所在的项目。")]; return }
        request = Request(query: text, scope: scope, location: location, sessions: scopedSessions)
    }
    private func submit(_ rows: [Result]) {
        if let row = rows.first(where: { $0.id == selection && $0.enabled }) { open(row) }
        else if let row = rows.first(where: \.enabled), ["会话", "成果"].contains(scope) { open(row) }
        else { search() }
    }
    private func move(_ delta: Int, key: KeyPress, rows: [Result]) -> KeyPress.Result {
        guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true,
              !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[min(max(index + delta, 0), rows.count - 1)].id
        return .handled
    }
    private func open(_ row: Result) {
        guard row.enabled else { return }
        switch row.destination {
        case .session(let item): model.open(item)
        case .history(let hit):
            model.open(hit.session); model.showConversationFind = true
            model.workspaceSearchQuery = request?.query ?? query
            model.workspaceSearchEntryID = hit.entryID
        case .outcome(let outcome): model.openOutcome(outcome)
        case .file(let hit):
            model.openWorkspaceFile(GroupOutcome(title: (hit.path as NSString).lastPathComponent, link: hit.path),
                                    location: request?.location, line: hit.line)
        }
        dismiss()
    }
}
