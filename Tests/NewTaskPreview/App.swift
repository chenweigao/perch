import AppKit
import SwiftUI
import WorkbenchCore

/// Visual fixture with local and fake remote hosts in its own defaults domain.
/// The simulated-ready control uses in-process transports; auto-connect is off.
@main struct NewTaskPreviewApp: App {
    @NSApplicationDelegateAdaptor(NewTaskPreviewDelegate.self) private var delegate
    @StateObject private var model: WorkbenchModel
    @Environment(\.openWindow) private var openWindow
    @State private var showPreviewControls = true
    @State private var selectedDirectory = "/opt/demo/perch"

    init() {
        let host = SSHHost(id: ExecutionEnvironment.localHostID, name: "本机预览", destination: "", enabledAgents: [.kimi, .omp, .codex],
                           autoConnectSSH: false, autoConnectHerdr: false)
        let remote = SSHHost(name: "远程预览", destination: "fixture.invalid", enabledAgents: [.kimi, .codex], autoConnectSSH: false, autoConnectHerdr: false)
        UserDefaults.standard.set(try? JSONEncoder().encode([host, remote]), forKey: "hosts")
        let directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("new-task-fixture").path
        UserDefaults.standard.set(directory, forKey: "new.cwd.\(host.id.uuidString)")
        UserDefaults.standard.set("fixture-model", forKey: "new.model.kimi")
        UserDefaults.standard.set("把登录页改成两栏布局，左侧放品牌插画", forKey: "new.task.prompt")
        let model = WorkbenchModel()
        model.kimi.models = previewModels
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("新建任务预览", id: ProcessInfo.processInfo.environment["PERCH_PREVIEW_NARROW"] == "1" ? "narrow-workflow" : "regular-workflow") {
            NewTaskView(model: model, native: model.native, kimi: model.kimi)
                .preferredColorScheme(.light)
                .toolbar {
                    if showPreviewControls {
                    Button("项目选择预览") { openWindow(id: "project-picker") }
                    Button("模拟就绪") {
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.protocolClasses = [NewTaskPreviewProtocol.self]
                        let connection = KimiConnection(host: model.kimi.host,
                            api: KimiAPI(baseURL: URL(string: "https://fixture.invalid")!, token: "fixture", configuration: configuration))
                        connection.models = previewModels
                        model.kimi = connection
                        model.native = NativeAgentConnection(host: model.native.host) { _, _ in Data(#"{"models":[]}"#.utf8) }
                    }
                    Button("模拟连接错误") { model.kimi.error = "预览：连接超时，请检查运行环境。" }
                    Button("清除错误") { model.kimi.error = nil }
                    Button("隐藏预览控件") { showPreviewControls = false }
                    }
                }
        }.defaultSize(width: ProcessInfo.processInfo.environment["PERCH_PREVIEW_NARROW"] == "1" ? 620 : 1100, height: 760)
        Window("项目选择预览", id: "project-picker") {
            VStack {
                NewTaskDirectoryPicker(host: SSHHost(id: ExecutionEnvironment.localHostID, name: "本机预览", destination: "", enabledAgents: [.kimi], autoConnectSSH: false, autoConnectHerdr: false),
                    cwd: $selectedDirectory, recent: ["/opt/demo/perch", "/opt/demo/perch-docs", "/opt/demo/agent-service"]) {}
                Text(selectedDirectory).font(.caption).padding(.bottom)
            }.preferredColorScheme(.light)
        }.defaultSize(width: 420, height: 410)

    }
}

final class NewTaskPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Screenshot helper: the window number doubles as the CGWindowID.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let window = NSApp.windows.first {
                print("WINDOW_ID=\(window.windowNumber)")
                fflush(stdout)
            }
        }
    }
}

private let previewModels: [JSONValue] = [.object([
    "model": .string("fixture-model"), "provider": .string("fixture"), "display_name": .string("Preview Model"),
    "support_efforts": .array([.string("low"), .string("high")]), "default_effort": .string("high")
])]

/// All simulated requests stay in-process, including an accidental send.
final class NewTaskPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isCatalog = request.url?.path == "/api/v1/models"
        let body: JSONValue = isCatalog ? .object(["items": .array(previewModels)]) : .object(["error": .string("Preview only")])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: isCatalog ? 200 : 400,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
