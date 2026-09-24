import Foundation
import Security
import SwiftUI
import WorkbenchCore

/// Only endpoint preferences go in defaults. The optional credential stays in
/// this Mac's Keychain and is never part of a workspace or conversation export.
@MainActor final class ActivitySummarySettings: ObservableObject {
    static let shared = ActivitySummarySettings()
    private static let defaultsKey = "perch.activitySummary"
    @Published private(set) var configuration: ActivitySummaryConfiguration
    @Published private(set) var revision = 0
    private init() {
        configuration = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(ActivitySummaryConfiguration.self, from: $0) } ?? .init()
    }
    func apiKey(allowInteraction: Bool = false) async throws -> String {
        try await Task.detached(priority: .utility) {
            try ActivitySummaryCredential.read(allowInteraction: allowInteraction)
        }.value
    }
    func save(_ value: ActivitySummaryConfiguration, apiKey: String) async throws {
        if value.enabled && !value.isValid { throw ActivitySummaryError.configuration }
        try await Task.detached(priority: .utility) {
            try ActivitySummaryCredential.write(apiKey)
        }.value
        try updateConfiguration(value)
    }
    func updateConfiguration(_ value: ActivitySummaryConfiguration) throws {
        if value.enabled && !value.isValid { throw ActivitySummaryError.configuration }
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: Self.defaultsKey)
        configuration = value
        revision += 1
    }
    func disable() {
        configuration.enabled = false
        UserDefaults.standard.set(try? JSONEncoder().encode(configuration), forKey: Self.defaultsKey)
        revision += 1
    }
}

/// Security.framework can wait on securityd or an authorization dialog. Never
/// perform these synchronous calls on the UI executor. Background requests must
/// fail with a retryable error instead of opening a credential dialog.
private enum ActivitySummaryCredential {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.agentworkbench.activity-summary",
         kSecAttrAccount as String: "api-key"]
    }
    static func read(allowInteraction: Bool) throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        if !allowInteraction { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ apiKey: String) throws {
        let status: OSStatus
        if apiKey.isEmpty { status = SecItemDelete(query as CFDictionary) }
        else {
            let attributes = [kSecValueData as String: Data(apiKey.utf8)]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || (apiKey.isEmpty && status == errSecItemNotFound) else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: L("无法访问摘要服务的钥匙串凭据。")])
    }
}

struct ActivitySummarySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = ActivitySummarySettings.shared
    @State private var configuration = ActivitySummaryConfiguration()
    @State private var apiKey = ""
    @State private var error: String?
    @State private var testResult: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var credentialLoaded = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("活动叙事与 Recap").font(.title2)
            Text("Perch 会优先使用 Agent 原生摘要或明确进度，并在本机即时生成阶段标题。可选的外部服务默认关闭；开启后才会发送受限信息，并可能产生额外费用。Recap 只在你点击时生成。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Toggle("启用外部摘要与 Recap", isOn: $configuration.enabled)
                Toggle("自动命名会话", isOn: $configuration.nameSessions)
                    .disabled(!configuration.enabled)
                    .help("会话标题仍是占位值（未命名、新对话或首条消息截断）时生成一次短标题，写入本机显示名；手动重命名优先。")
                TextField("Base URL（含 /v1）", text: $configuration.baseURL, prompt: Text("http://localhost:8000/v1"))
                TextField("模型名称", text: $configuration.model, prompt: Text("qwen3.8-flash-next"))
                SecureField("API Key（可选，保存在钥匙串）", text: $apiKey)
                Toggle("附带工具输出摘录", isOn: $configuration.includeToolOutput)
                    .disabled(!configuration.enabled)
                    .help("默认关闭。开启后，每条工具结果最多发送 600 字符的文本摘录，可能包含源码、命令或其他敏感内容。")
                Toggle("关闭 Qwen 思考", isOn: $configuration.disableThinking)
                    .help("仅用于支持 chat_template_kwargs.enable_thinking 的服务，可减少摘要的延迟与开销。")
            }
            Text("使用 OpenAI 兼容的 Chat Completions 接口。活动叙事发送当前轮公开文本和受限工具元数据；手动 Recap 会按需读取完整分页历史，再发送最多 12 轮公开用户/Agent 文本、Todo，以及最多 24 条工具类型、截短目标、状态和可用退出码。工具输出摘录需单独开启；不发送完整命令参数、编辑内容、私有思考或运行上下文。自动命名仍只发送首条用户消息开头。所有内容都不会写回 Agent 上下文。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
            HStack {
                Button(testing ? "正在测试…" : "测试连接（发送示例）") { test() }
                    .disabled(testing || saving || !configuration.isValid || !credentialLoaded)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await settings.save(configuration, apiKey: apiKey); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(testing || saving || !credentialLoaded || (configuration.enabled && !configuration.isValid))
            }
        }.padding(24).frame(width: 540)
            .task {
                configuration = settings.configuration
                do { apiKey = try await settings.apiKey(allowInteraction: true); credentialLoaded = true }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { testTask?.cancel() }
    }
    private func test() {
        testing = true; error = nil; testResult = nil
        var config = configuration
        config.enabled = true // A deliberate test does not enable background work.
        let key = apiKey
        let tools = ["ModelSelection.swift", "NativeAgentView.swift"].enumerated().map {
            VisibleTool(id: "example-\($0.offset)", name: "Read", input: .object(["path": .string($0.element)]), status: .returned)
        }
        testTask = Task {
            defer { testing = false }
            do {
                let result = try await ActivitySummaryClient().summarize(configuration: config, apiKey: key,
                    batch: .init(groupID: "example", tools: tools, closed: true), language: AppLanguage.current.localization)
                guard !Task.isCancelled else { return }
                testResult = L("摘要测试通过：\(result.summary)")
                if config.nameSessions {
                    let name = try await SessionNamingClient().name(configuration: config, apiKey: key,
                        excerpt: "Improve the model picker in a sample coding app", language: AppLanguage.current.localization)
                    if !Task.isCancelled { testResult = L("摘要与自动命名测试通过。示例名称：\(name)") }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
