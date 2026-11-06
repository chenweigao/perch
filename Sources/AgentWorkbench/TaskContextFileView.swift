import SwiftUI
import WorkbenchCore

struct TaskContextFileRoute: Hashable {
    let source: SessionReference
    let path: String
    let name: String
}

/// A task's file stays bound to that task, including when the panel is locked
/// beside another conversation. Only explicit expansion opens a reader window.
struct TaskContextFileView: View {
    let model: WorkbenchModel
    let item: WorkspaceSession
    let route: TaskContextFileRoute
    @State private var browser: RemoteFileBrowser

    init(model: WorkbenchModel, item: WorkspaceSession, route: TaskContextFileRoute) {
        self.model = model
        self.item = item
        self.route = route
        // The parent keys this view by route; requests remain page-owned while
        // reading choices belong to the captured source session.
        _browser = State(initialValue: RemoteFileBrowser(
            documents: model.taskContextWindow.readingState(for: route.source).files))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    model.taskContextWindow.fileDetail = nil
                } label: {
                    Label("任务面板", systemImage: "chevron.left")
                }.accessibilityIdentifier("task-context-file-back")
                Spacer(minLength: 4)
                Button("展开阅读") {
                    model.openWorkspaceFile(GroupOutcome(title: route.name, link: browser.path, source: route.source))
                }.disabled(browser.path.isEmpty || browser.loading || !item.online)
            }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 10)
            Text(route.name).font(.system(size: WorkbenchTheme.Typography.title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).padding(.horizontal, 16).padding(.bottom, 10)
            if !item.online {
                Label("状态未同步", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 10)
            }
            RemoteFilePanel(browser: browser, showsCloseButton: false, compact: true,
                            onClose: { model.taskContextWindow.fileDetail = nil })
        }.font(.system(size: WorkbenchTheme.Typography.body))
            .workbenchHostedTask(id: item.online) {
                guard item.online else { browser.cancel(); return }
                let host = model.connections.first { $0.id == route.source.hostID }?.host
                browser.source = route.source
                browser.configure(host: host, cwd: item.directory,
                                  directoryHints: model.selectedDirectoryHints(item.directory, reference: route.source))
                browser.open(route.path, fromConversation: true, source: route.source)
            }
            .onDisappear { browser.cancel() }
    }
}
