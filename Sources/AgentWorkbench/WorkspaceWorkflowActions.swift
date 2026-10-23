import AppKit
import WorkbenchCore

extension WorkbenchModel {
    var workbenchProjects: [SidebarProject] {
        SidebarProjection(sessions: allSessions, starred: [], projectLocations: sidebarProjectLocations).projects
    }
    func projectSessions(_ location: SidebarProjectLocation) -> [WorkspaceSession] {
        workbenchProjects.first { $0.id == location.id }?.sessions ?? []
    }
    func updateBrief(_ brief: ProjectBrief, for location: SidebarProjectLocation) {
        workspace.projectBriefs[location.id] = brief; saveWorkspace()
    }
    func toggleFollow(_ session: SessionReference) {
        if workspace.followedSessions.contains(session) { workspace.followedSessions.removeAll { $0 == session } }
        else { workspace.followedSessions.append(session) }
        saveWorkspace()
    }
    func saveDelivery(_ record: DeliveryRecord) {
        if let index = workspace.deliveries.firstIndex(where: { $0.id == record.id }) { workspace.deliveries[index] = record }
        else { workspace.deliveries.append(record) }
        saveWorkspace()
    }
    func openOutcome(_ outcome: GroupOutcome) {
        if let url = outcome.webURL { NSWorkspace.shared.open(url) }
        else { openWorkspaceFile(outcome) }
    }
    /// All file entry points share the native window. Reading never selects a conversation.
    func openWorkspaceFile(_ outcome: GroupOutcome, location: SidebarProjectLocation? = nil, line: Int? = nil) {
        let source = outcome.source.flatMap { reference in allSessions.first { $0.reference == reference } }
        guard let hostID = source?.reference.hostID ?? location?.hostID,
              let host = connections.first(where: { $0.id == hostID })?.host else {
            fileBrowser.cancel()
            pendingFileOutcome = outcome
            showFileViewer = true
            fileWindow.show(model: self)
            return
        }
        pendingFileOutcome = nil
        fileBrowser.source = source?.reference
        fileBrowser.configure(host: host, cwd: source?.directory ?? location?.directory ?? "")
        fileBrowser.open(outcome.link, line: line, fromConversation: true, source: source?.reference)
        showFileViewer = true
        fileWindow.show(model: self)
    }

    func addFollowUp(_ rule: FollowUpRule) {
        workspace.followUps.append(rule); saveWorkspace()
    }
    func cancelFollowUp(_ id: UUID) {
        guard let index = workspace.followUps.firstIndex(where: { $0.id == id }), [.pending, .needsReview].contains(workspace.followUps[index].status) else { return }
        workspace.followUps[index].status = .cancelled; saveWorkspace()
    }
    /// A connection-scoped loop: hiding or closing the companion does not stop it.
    /// Every send uses a stable outbox ID and never touches the conversation draft.
    func startFollowUpLoop() {
        guard followUpLoop == nil else { return }
        followUpLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.processFollowUps(now: Date())
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
    func processFollowUps(now: Date) {
        var changed = false
        for index in workspace.followUps.indices {
            let rule = workspace.followUps[index]
            let item = allSessions.first { $0.reference == rule.session }
            guard rule.isDue(session: item, now: now) else { continue }
            if rule.trigger == .inactivity {
                workspace.followUps[index].status = .notified
                followUpNotices.append(rule.title)
                notifyInactiveTask(rule)
                changed = true; continue
            }
            guard let agents = agentConnections(for: rule.session.hostID) else { continue }
            // If interrupted after this durable intent, never automatically repeat
            // an ambiguously accepted send after restart. The user checks its queue.
            workspace.followUps[index].status = .needsReview
            do { try persistFollowUpIntent() }
            catch { workspaceError = error.localizedDescription; changed = true; continue }
            let accepted = rule.session.kind == .kimi
                ? agents.kimi.enqueueFollowUp(rule.prompt, for: rule.session.terminalID, messageID: rule.messageID)
                : agents.native.enqueueFollowUp(rule.prompt, for: rule.session.terminalID, messageID: rule.messageID)
            if accepted { workspace.followUps[index].status = .queued }
            changed = true
        }
        if changed { saveWorkspace() }
    }
    @discardableResult func sendCompanionReply(_ text: String, to reference: SessionReference) -> Bool {
        guard reference.kind != .terminal, let item = allSessions.first(where: { $0.reference == reference }), item.online, !item.archived,
              item.section != .attention, let agents = agentConnections(for: reference.hostID) else { return false }
        let id = "perch-companion-\(UUID().uuidString)"
        return reference.kind == .kimi ? agents.kimi.enqueueFollowUp(text, for: reference.terminalID, messageID: id)
            : agents.native.enqueueFollowUp(text, for: reference.terminalID, messageID: id)
    }
}

/// Keep actionable requests ahead of unread results, running work and stale status.
func workspaceTaskPriority(_ item: WorkspaceSession) -> Int {
    guard item.online && !item.archived else { return 4 }
    switch item.section {
    case .attention: return 0
    case .review: return 1
    case .running: return 2
    default: return 3
    }
}
