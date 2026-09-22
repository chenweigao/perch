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
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.agentworkbench.activity-summary",
         kSecAttrAccount as String: "api-key"]
    }
    func apiKey() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw keychainError(status) }
        return String(decoding: data, as: UTF8.self)
    }
    func save(_ value: ActivitySummaryConfiguration, apiKey: String) throws {
        if value.enabled && !value.isValid { throw ActivitySummaryError.configuration }
        let data = try JSONEncoder().encode(value)
        let status: OSStatus
        if apiKey.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let attributes = [kSecValueData as String: Data(apiKey.utf8)]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if update == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = update }
        }
        guard status == errSecSuccess || (apiKey.isEmpty && status == errSecItemNotFound) else { throw keychainError(status) }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        configuration = value
        revision += 1
    }
    func disable() {
        configuration.enabled = false
        UserDefaults.standard.set(try? JSONEncoder().encode(configuration), forKey: Self.defaultsKey)
        revision += 1
    }
    private func keychainError(_ status: OSStatus) -> NSError {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("活动摘要").font(.title2)
            Text("可选功能，默认关闭。开启后，当前会话的工具名称、文件名或搜索词及执行状态会发送到你配置的服务；可能产生额外费用。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Toggle("启用活动摘要", isOn: $configuration.enabled)
                TextField("Base URL（含 /v1）", text: $configuration.baseURL, prompt: Text("http://localhost:8000/v1"))
                TextField("模型名称", text: $configuration.model, prompt: Text("qwen3.8-flash-next"))
                SecureField("API Key（可选，保存在钥匙串）", text: $apiKey)
                Toggle("关闭 Qwen 思考", isOn: $configuration.disableThinking)
                    .help("仅用于支持 chat_template_kwargs.enable_thinking 的服务，可减少摘要的延迟与开销。")
            }
            Text("使用 OpenAI 兼容的 Chat Completions 接口。不会发送源码、工具输出、思考内容或用户消息；不会写回 Agent 的上下文。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
            HStack {
                Button(testing ? "正在测试…" : "测试连接（发送示例）") { test() }
                    .disabled(testing || !configuration.isValid || !credentialLoaded)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try settings.save(configuration, apiKey: apiKey); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(testing || !credentialLoaded || (configuration.enabled && !configuration.isValid))
            }
        }.padding(24).frame(width: 540)
            .onAppear {
                configuration = settings.configuration
                do { apiKey = try settings.apiKey(); credentialLoaded = true }
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
                if !Task.isCancelled { testResult = result }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
