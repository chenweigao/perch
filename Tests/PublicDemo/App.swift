import AppKit
import SwiftUI
import WorkbenchCore

// Offline presentation of production views. No connection, workspace or history loader.
@main struct PublicDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Perch · 演示数据") { PublicDemo().preferredColorScheme(.light) }
            .defaultSize(width: 1280, height: 850)
        Settings { Text("演示窗口不保存设置，也不连接 Agent。").padding(32) }
    }
}

private struct PublicDemo: View {
    @State private var selected = 0
    @State private var draft = ""
    @State private var model = ""
    @State private var pinned = true
    @State private var showNotice = false
    private let titles = ["修复登录后的页面跳转", "补全登录回归测试"]
    private let messages: [KimiMessage] = {
        let rows: [[String: Any]] = [
            ["id": "request", "role": "user", "created_at": "1", "content": [["type": "text", "text": "登录后总是回到首页。请保留用户原来想访问的页面，并补上测试。"]]],
            ["id": "progress", "role": "assistant", "created_at": "2", "content": [["type": "text", "text": "问题出在登录回调：它忽略了原始路径。我会保留站内跳转，并拒绝外部地址。"]]],
            ["id": "call", "role": "assistant", "created_at": "3", "content": [["type": "tool_use", "tool_call_id": "test", "tool_name": "Shell", "input": ["command": "npm test -- auth", "description": "检查登录回归测试"]]]],
            ["id": "result", "role": "tool", "created_at": "4", "content": [["type": "tool_result", "tool_call_id": "test", "is_error": false, "output": "PASS  tests/auth.test.ts\n  ✓ returns to the requested page\n  ✓ falls back to home when no path is present\n  ✓ rejects external redirect URLs\n\nTests: 3 passed, 3 total\nSynthetic demo output — no command was executed."]]],
            ["id": "answer", "role": "assistant", "created_at": "5", "content": [["type": "text", "text": """
            已修复。**登录后会回到原页面**；没有目标路径时，仍然进入首页。

            ### 做了哪些调整

            - 在 `src/auth/callback.ts` 中保留原始站内路径。
            - 外部地址统一回退到 `/`，避免开放重定向。
            - 补充原路径、默认首页和外部地址三种回归场景。

            ### 验证结果

            示例中的 **3 项测试全部通过**。下面是核心判断：

            ```typescript
            const destination = isSafeLocalPath(returnTo) ? returnTo : "/";
            router.replace(destination);
            ```

            可以继续检查登录页的错误提示，让异常状态也保持清晰。
            """]]]
        ]
        return try! KimiWire.decoder().decode([KimiMessage].self, from: JSONSerialization.data(withJSONObject: rows))
    }()

    var body: some View {
        WorkspaceSplitView(newConversation: { showNotice = true }) {
            WorkspaceSidebarShell(page: .other, attentionCount: 0, environmentSummary: "演示环境",
                                  onSearch: { showNotice = true },
                                  onNew: { showNotice = true },
                                  onHome: { selected = 0 }, onInbox: { showNotice = true },
                                  onArchive: { showNotice = true }) {
                section("置顶")
                row(0, symbol: "bubble.left.and.bubble.right")
                section("任务组")
                Label("Hello Perch", systemImage: "folder").padding(.horizontal, 10).padding(.vertical, 8)
                section("最近会话")
                row(1, symbol: "bubble.left.and.bubble.right")
                Label("整理项目文档", systemImage: "bubble.left.and.bubble.right").padding(10).foregroundStyle(.secondary)
                Label("检查构建脚本", systemImage: "terminal").padding(10).foregroundStyle(.secondary)
            } environments: {
                VStack(alignment: .leading, spacing: 12) {
                    Label("demo-server", systemImage: "server.rack")
                    Text("离线演示 · 不连接远端").foregroundStyle(.secondary)
                }.padding(20)
            }
        } header: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text(titles[selected])
            }.font(.system(size: 13, weight: .semibold)).fixedSize()
        } actions: {
            HStack(spacing: 16) {
                Label("Hello Perch", systemImage: "folder").labelStyle(.titleAndIcon).foregroundStyle(.secondary).fixedSize()
                Button { showNotice = true } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.plain)
            }.font(.system(size: 12))
        } content: {
            VStack(spacing: 0) {
                ConversationScrollView(showsScrollIndicator: false, onScroll: { _ in }, onContentSizeChange: {}) {
                    VStack(alignment: .leading, spacing: 18) {
                        if selected == 0 {
                            ConversationTranscript(messages: messages, sessionId: "public-demo")
                        } else {
                            KimiMarkdown(text: "已补充登录回归测试。展开下面的工具记录，可查看命令参数和示例结果。")
                            KimiToolCard(tool: VisibleTool(id: "demo-tool", name: "Shell",
                                input: .object(["command": .string("npm test -- auth"), "description": .string("运行登录回归测试")]),
                                output: .string("PASS  tests/auth.test.ts\n\n✓ returns to the requested page\n✓ falls back to home\n✓ rejects external URLs\n\nTests: 3 passed, 3 total\n\nSynthetic demo output — no command was executed."), status: .succeeded))
                            KimiMarkdown(text: "测试文件：`tests/auth.test.ts`\n\n覆盖原页面恢复、缺省路径和站外跳转三个场景。")
                        }
                    }.frame(maxWidth: ReplyStyle.readingWidth, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: .infinity)
                }
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        MessageComposer(text: $draft, accessibilityLabel: "演示草稿", canSend: false, onSend: {})
                        HStack {
                            Image(systemName: "plus").foregroundStyle(.secondary)
                            ModelPicker(models: [], selection: $model)
                            Spacer()
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)).foregroundStyle(.tertiary)
                        }
                    }.padding(16).workbenchControlSurface()
                    Text("演示数据 · 离线预览 · 未执行真实命令")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: ReplyStyle.readingWidth).padding(.horizontal, 28).padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
            }
        }.alert("离线演示", isPresented: $showNotice) {
            Button("知道了", role: .cancel) {}
        } message: { Text("此窗口只展示虚构内容，不加载真实会话或执行命令。") }
    }
    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 36).padding(.trailing, 10).padding(.top, 17).padding(.bottom, 6)
    }
    private func row(_ index: Int, symbol: String) -> some View {
        SessionRowChrome(title: titles[index], subtitle: nil, selected: selected == index,
                         starred: index == 0 && pinned, archived: false, canOpen: true,
                         canQuickArchive: false, busy: false, onOpen: { selected = index },
                         onPin: { if index == 0 { pinned.toggle() } }, onArchive: {}) {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

private final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
