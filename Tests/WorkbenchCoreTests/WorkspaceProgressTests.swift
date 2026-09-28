import Foundation
import WorkbenchCore

func checkWorkspaceProgress() throws {
    let ref = SessionReference(hostID: UUID(), terminalID: "one", kind: .codex)
    var group = WorkItemGroup(name: "交付", goal: "验证与交付", nextStep: "验收", sessions: [ref])
    let original = try JSONEncoder().encode(group)
    var legacy = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    legacy.removeValue(forKey: "criteria"); legacy.removeValue(forKey: "outcomes"); legacy.removeValue(forKey: "stage")
    let migrated = try JSONDecoder().decode(WorkItemGroup.self, from: JSONSerialization.data(withJSONObject: legacy))
    precondition(migrated.id == group.id && migrated.sessions == [ref] && migrated.criteria.isEmpty && migrated.stage == .active)
    group.criteria = [GroupCriterion(title: "通过验收", completed: true)]
    group.outcomes = [GroupOutcome(title: "报告", detail: "已验证", link: "https://example.com/report", source: ref)]
    group.stage = .completed
    var workspace = LocalWorkspace(); workspace.groups = [group]
    workspace.dashboardSeen[ref.id] = DashboardObservation(state: "review", revision: "1")
    let restored = try JSONDecoder().decode(LocalWorkspace.self, from: JSONEncoder().encode(workspace))
    precondition(restored == workspace)
    precondition(GroupOutcome(title: "bad", link: "javascript:alert(1)").webURL == nil)
    precondition(GroupOutcome(title: "remote", link: "/home/user/report.md").webURL == nil)
    let prior = DashboardObservation(state: "review", revision: "1")
    precondition(!prior.isNew(since: prior))
    precondition(DashboardObservation(state: "review", revision: "2").isNew(since: prior))
    precondition(DashboardObservation(state: "attention", revision: "question:2").isNew(since: prior))
    precondition(!DashboardObservation(state: "running", revision: "new").isNew(since: prior))
    precondition(!DashboardObservation(state: "other", revision: "new").isNew(since: nil))
    var order = ActionQueueOrder(); order.update(["a", "b"]); order.update(["c", "b", "a"])
    precondition(order.ids == ["a", "b", "c"] && order.next(after: "a") == "b")
    order.update(["b", "c"]); precondition(order.next(after: "a") == "b")
    order.update(["b"]); precondition(order.next(after: "b") == nil)
    print("PASS: workspace progress migration, independent checkpoints, safe outcome links, stable action order")
}

func checkGroupSuggestions() throws {
    let host = UUID()
    let ref = SessionReference(hostID: host, terminalID: "new", kind: .kimi)
    let session = WorkspaceSession(reference: ref, title: "修复滚动", directory: "/home/user/project/perch",
        hostName: "dev", detail: "", online: true, section: .other, canMarkReviewed: false)
    let group = WorkItemGroup(name: "滚动体验", goal: "稳定滚动", nextStep: "", sessions: [])
    let other = WorkItemGroup(name: "已有分组", goal: "", nextStep: "", sessions: [ref])
    let input = GroupingInput(groups: [group, other], sessions: [session])
    func response(_ proposals: [[String: String]], finish: String = "stop") throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["suggestions": proposals]), as: UTF8.self)
        return try rawResponse(content, finish: finish)
    }
    func rawResponse(_ content: String, finish: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": finish]]])
    }
    let proposal = ["sessionID": ref.id, "groupID": group.id.uuidString, "reason": "目标与会话均关于滚动"]
    let data = try response([proposal, proposal,
        ["sessionID": "invented", "groupID": group.id.uuidString, "reason": "bad"],
        ["sessionID": ref.id, "groupID": other.id.uuidString, "reason": "already linked"]])
    let suggestions = try GroupingClient.parse(data, input: input)
    precondition(suggestions.count == 1)
    let complete = String(decoding: try JSONSerialization.data(withJSONObject: ["suggestions": [proposal, proposal]]), as: UTF8.self)
    let completeMarkedLength = try GroupingClient.parse(rawResponse(complete, finish: "length"), input: input)
    precondition(completeMarkedLength.count == 1)
    let cut = complete.firstIndex(of: "}")!
    let salvaged = try GroupingClient.parse(rawResponse(String(complete[...cut]), finish: "length"), input: input)
    precondition(salvaged.count == 1 && salvaged[0].sessionID == ref.id)
    do { _ = try GroupingClient.parse(rawResponse("{\"suggestions\":[{\"sessionID\":\"\(ref.id)\",", finish: "length"), input: input); preconditionFailure("unsalvageable truncation accepted") }
    catch ActivitySummaryError.truncated { }
    var workspace = LocalWorkspace(); workspace.groups = [group, other]
    let undo = workspace.applyGrouping(suggestions, sessions: [session])
    precondition(workspace.groups[0].sessions == [ref] && workspace.groups[1] == other)
    let second = workspace.applyGrouping(suggestions, sessions: [session]); precondition(second.before.isEmpty)
    precondition(workspace.undoGrouping(undo) && workspace.groups == [group, other])
    let freshUndo = workspace.applyGrouping(suggestions, sessions: [session])
    workspace.groups[0].sessions.append(SessionReference(hostID: host, terminalID: "manual"))
    precondition(!workspace.undoGrouping(freshUndo) && workspace.groups[0].sessions.count == 2)
    workspace.groups.removeFirst()
    _ = workspace.applyGrouping(suggestions, sessions: [session]); precondition(workspace.groups == [other])
    var config = ActivitySummaryConfiguration()
    config.enabled = true; config.baseURL = "https://example.com/v1"; config.model = "fixture-model"
    config.disableThinking = true
    let request = try GroupingClient().request(configuration: config, apiKey: "test-key", input: input, language: "zh-Hans")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    precondition(request.url?.absoluteString == "https://example.com/v1/chat/completions")
    precondition(body["tools"] == nil && body["stream"] as? Bool == false)
    precondition((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    precondition(!String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
    config.enabled = false
    do {
        _ = try GroupingClient().request(configuration: config, apiKey: "", input: input, language: "en")
        preconditionFailure("Disabled grouping service accepted a request")
    } catch ActivitySummaryError.configuration { }
    let manySessions = (0..<60).map { index in
        WorkspaceSession(reference: SessionReference(hostID: host, terminalID: "batch-\(index)"), title: "task", directory: "",
                         hostName: "", detail: "", online: false, section: .other, canMarkReviewed: false)
    }
    var broadGroup = group; broadGroup.sessions = Array(manySessions.prefix(50).map(\.reference))
    let bounded = GroupingInput(groups: [broadGroup], sessions: manySessions)
    precondition(bounded.sessions.count == 40 && bounded.sessions[0].id == manySessions[50].id)
    precondition(bounded.groups[0].examples.count == 6)
    let encoded = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
    precondition(!encoded.contains("/home/user") && !encoded.contains("hostName"))
    print("PASS: grouping rejects unknown/duplicate memberships, preserves manual changes, undo conflicts and bounded metadata")
}
