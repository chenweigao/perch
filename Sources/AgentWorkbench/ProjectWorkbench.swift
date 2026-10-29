import SwiftUI
import WorkbenchCore

struct ProjectWorkbenchOverview: View {
    @Bindable var model: WorkbenchModel
    var body: some View {
        if model.selectedGroup == nil {
            let projects = model.workbenchProjects.filter { model.scopeHost == nil || $0.location?.hostID == model.scopeHost?.id }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("项目工作台").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("长任务托管") { model.showFollowUps = true }.buttonStyle(QuietLinkStyle())
                }
                if !model.followUpNotices.isEmpty {
                    Label("有 \(model.followUpNotices.count) 个任务长时间没有更新", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if projects.isEmpty {
                    Text("项目会随会话自动出现。").foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    if let location = project.location {
                        Button { model.projectOverview = location } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(project.title).fontWeight(.medium)
                                    Text(location.hostName).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                let brief = model.workspace.projectBriefs[location.id] ?? ProjectBrief()
                                if !brief.nextStep.isEmpty { Text("下一步：\(brief.nextStep)").lineLimit(2) }
                                else if !brief.goal.isEmpty { Text(brief.goal).lineLimit(2) }
                                let waiting = project.sessions.filter { $0.online && $0.section == .attention }.count
                                let results = project.sessions.filter { $0.online && $0.section == .review }.count
                                Text("\(project.sessions.count) 个会话 · \(waiting) 项待处理 · \(results) 项结果待查看")
                                    .foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 8)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.font(.system(size: 12))
        }
    }
}

struct ProjectWorkbenchSheet: View {
    @Bindable var model: WorkbenchModel
    let location: SidebarProjectLocation
    @Environment(\.dismiss) private var dismiss
    @State private var brief = ProjectBrief()
    @State private var editingDelivery: DeliveryRecord?
    @State private var editingBrief = false
    @State private var briefDraft = ProjectBrief()
    private var sessions: [WorkspaceSession] { model.projectSessions(location) }
    private var groups: [WorkItemGroup] {
        let ids = Set(sessions.map(\.reference))
        return model.workspace.groups.filter { !$0.sessions.allSatisfy { !ids.contains($0) } }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(location.name).font(.title2)
                Button { briefDraft = brief; editingBrief.toggle() } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("项目详情")
                    .popover(isPresented: $editingBrief) { projectDetails }
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !brief.nextStep.isEmpty { Text("下一步：\(brief.nextStep)").foregroundStyle(.secondary) }
                    focusSection("需要你处理", items: sessions.filter { $0.online && !$0.archived && $0.section == .attention })
                    let results = sessions.filter { $0.online && !$0.archived && $0.section == .review && $0.updatedAt > brief.seenAt }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("新完成的结果").font(.headline); Spacer()
                            Button("确认看过") { brief.seenAt = Date().timeIntervalSince1970; model.updateBrief(brief, for: location) }
                                .disabled(results.isEmpty)
                        }
                        if results.isEmpty { Text("暂无新的请求或结果").foregroundStyle(.secondary) }
                        ForEach(results) { item in sessionRow(item) }
                    }
                    focusSection("进行中", items: sessions.filter { $0.online && !$0.archived && $0.section == .running })
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("关联目标与成果").font(.headline)
                            ForEach(groups) { group in
                                Button(group.name) { dismiss(); model.showHome(groupID: group.id) }.buttonStyle(QuietLinkStyle())
                                ForEach(group.outcomes) { outcome in
                                    Button { if let url = outcome.webURL { NSWorkspace.shared.open(url) } else { model.openWorkspaceFile(outcome, location: location); dismiss() } } label: {
                                        Label(outcome.title, systemImage: outcome.webURL == nil ? "doc.text" : "link")
                                    }.buttonStyle(QuietLinkStyle())
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("交付与验收").font(.headline); Spacer()
                            Button("记录交付") { editingDelivery = DeliveryRecord(project: location, title: "", source: sessions.first?.reference) }
                        }
                        ForEach(model.workspace.deliveries.filter { $0.project.id == location.id }) { record in
                            Button { editingDelivery = record } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title).fontWeight(.medium)
                                    let acceptance = record.acceptanceCurrent ? L("已人工验收") : L("待人工验收")
                                    Text("验证：\(record.validation.title) · \(acceptance)")
                                        .foregroundStyle(.secondary)
                                    if let snapshot = record.snapshot {
                                        Text("PR 状态：\(snapshot.state) · \(snapshot.ciSummary)").foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    ProjectDocumentsSection(model: model, location: location)
                    DisclosureGroup("项目会话（\(sessions.count)）") {
                        ForEach(sessions) { item in sessionRow(item) }
                    }
                }.font(.system(size: 13)).padding(.bottom, 12)
            }
        }.padding(24).frame(width: 720, height: 700)
            .onAppear { brief = model.workspace.projectBriefs[location.id] ?? ProjectBrief() }
            .sheet(item: $editingDelivery) { record in DeliveryEditor(model: model, initial: record) }
    }
    private var projectDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(location.hostName) · \(location.directory)").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("项目目标", text: $briefDraft.goal, axis: .vertical)
            TextField("回来后先做什么", text: $briefDraft.nextStep, axis: .vertical)
            Button("保存目标与下一步") {
                brief.goal = briefDraft.goal; brief.nextStep = briefDraft.nextStep
                model.updateBrief(brief, for: location); editingBrief = false
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 360)
    }
    private func focusSection(_ title: LocalizedStringKey, items: [WorkspaceSession]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if items.isEmpty { Text("暂无任务").foregroundStyle(.secondary) }
            ForEach(items) { item in sessionRow(item) }
        }
    }
    private func sessionRow(_ item: WorkspaceSession) -> some View {
        HStack(alignment: .top) {
            Button { dismiss(); model.open(item) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(2)
                    Text(item.online ? L(key: item.section.rawValue) : L("状态未同步")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!item.online)
            Button(model.workspace.followedSessions.contains(item.reference) ? "取消关注" : "关注") { model.toggleFollow(item.reference) }
                .buttonStyle(QuietLinkStyle())
        }.padding(.vertical, 5)
    }
}

extension WorkbenchModel {
    func stageArtifactFeedback(_ text: String, to source: SessionReference) {
        guard let agents = agentConnections(for: source.hostID) else { return }
        let id = source.terminalID
        if source.kind == .kimi {
            let draft = agents.kimi.drafts[id] ?? ""; agents.kimi.drafts[id] = draft + (draft.isEmpty ? "" : "\n\n") + text
        } else if source.kind != .terminal {
            let draft = agents.native.drafts[id] ?? ""; agents.native.drafts[id] = draft + (draft.isEmpty ? "" : "\n\n") + text
        }
    }
}
