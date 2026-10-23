import SwiftUI
import WorkbenchCore

extension WorkbenchModel {
    private var readingProject: SidebarProjectLocation? {
        guard let host = fileBrowser.host, !fileBrowser.cwd.isEmpty else { return nil }
        let reference = fileBrowser.documents.current?.source ?? fileBrowser.source
        if let item = allSessions.first(where: { $0.reference == reference }),
           let project = sidebarProjectLocations[item.id], project.hostID == host.id { return project }
        return SidebarProjectLocation(hostID: host.id, directory: fileBrowser.cwd, hostName: host.name)
    }
    var documentLibraryActions: DocumentLibraryActions? {
        guard let project = readingProject else { return nil }
        let path = fileBrowser.path
        let pinned = workspace.documents.first { $0.project.id == project.id && $0.path == path }?.pinned ?? false
        return DocumentLibraryActions(pinned: pinned) { [weak self] in
            guard let self, self.fileBrowser.path == path else { return }
            self.recordReadDocument()
            guard let index = self.workspace.documents.firstIndex(where: { $0.project.id == project.id && $0.path == path }) else { return }
            self.workspace.documents[index].pinned.toggle(); self.saveWorkspace()
        }
    }
    func recordReadDocument() {
        guard let project = readingProject, !fileBrowser.path.isEmpty, fileBrowser.previewKind != .source else { return }
        switch fileBrowser.content { case .text, .binary: break; default: return }
        let path = fileBrowser.path
        let source = fileBrowser.documents.current?.source ?? fileBrowser.source
        if let index = workspace.documents.firstIndex(where: { $0.project.id == project.id && $0.path == path }) {
            workspace.documents[index].lastReadAt = Date().timeIntervalSince1970
            workspace.documents[index].modifiedAt = fileBrowser.modifiedAt
            workspace.documents[index].source = source
        } else {
            workspace.documents.append(ProjectDocument(project: project, path: path,
                title: (path as NSString).lastPathComponent, source: source, modifiedAt: fileBrowser.modifiedAt))
        }
        // Keep recent reading bounded without ever evicting a pinned document.
        let recent = workspace.documents.filter { !$0.pinned }.sorted { $0.lastReadAt > $1.lastReadAt }
        let retained = Set(recent.prefix(100).map(\.id))
        workspace.documents.removeAll { !$0.pinned && !retained.contains($0.id) }
        saveWorkspace()
    }
    func openProjectDocument(_ document: ProjectDocument) {
        guard let host = connections.first(where: { $0.id == document.project.hostID })?.host else { return }
        pendingFileOutcome = nil
        fileBrowser.source = document.source
        fileBrowser.configure(host: host, cwd: document.project.directory)
        fileBrowser.open(document.path, source: document.source)
        fileWindow.show(model: self); showFileViewer = true
    }
}

struct ProjectDocumentsSection: View {
    @Bindable var model: WorkbenchModel
    let location: SidebarProjectLocation
    @State private var showRecent = false
    private var documents: [ProjectDocument] {
        model.workspace.documents.filter { $0.project.id == location.id }.sorted {
            $0.pinned == $1.pinned ? $0.lastReadAt > $1.lastReadAt : $0.pinned
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("项目文档").font(.headline)
            if documents.isEmpty {
                Text("阅读文档后会显示在这里；可在文件菜单中固定常用文档。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(documents.filter(\.pinned)) { document in row(document) }
            DisclosureGroup("最近阅读", isExpanded: $showRecent) {
                ForEach(documents.filter { !$0.pinned }.prefix(12)) { document in row(document) }
            }
        }
    }
    private func row(_ document: ProjectDocument) -> some View {
        HStack(alignment: .top) {
            Button { model.openProjectDocument(document) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(document.title, systemImage: document.pinned ? "pin.fill" : "doc.text").lineLimit(2)
                    HStack {
                        Text("阅读于 \(Date(timeIntervalSince1970: document.lastReadAt).formatted(date: .abbreviated, time: .shortened))")
                        if let modified = document.modifiedAt {
                            Text("更新于 \(Date(timeIntervalSince1970: modified).formatted(date: .abbreviated, time: .shortened))")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(document.path)
                .disabled(!model.connections.contains { $0.id == document.project.hostID })
            Menu {
                Button(document.pinned ? "取消固定文档" : "固定到项目文档") {
                    if let index = model.workspace.documents.firstIndex(where: { $0.id == document.id }) {
                        model.workspace.documents[index].pinned.toggle(); model.saveWorkspace()
                    }
                }
                Button("从文档列表移除") {
                    model.workspace.documents.removeAll { $0.id == document.id }; model.saveWorkspace()
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("文档操作")
        }.padding(.vertical, 4)
    }
}
