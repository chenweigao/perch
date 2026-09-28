import AppKit
import SwiftUI
import WorkbenchCore

/// Project history belongs to the selected host; typing a path is a draft until confirmed.
struct NewTaskDirectoryPicker: View {
    let host: SSHHost
    @Binding var cwd: String
    let recent: [String]
    let onClose: () -> Void
    @State private var directoryDraft = ""
    @State private var directoryQuery = ""
    @FocusState private var cwdFocused: Bool
    private var matchingDirectories: [String] {
        let query = directoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? recent : recent.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目目录").font(.headline)
                Spacer()
                Text(host.name).font(.caption).foregroundStyle(.secondary)
            }
            if !recent.isEmpty {
                TextField("搜索最近项目", text: $directoryQuery).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if matchingDirectories.isEmpty {
                        Text(recent.isEmpty ? "还没有最近项目，可在下方输入目录。" : "没有匹配的项目")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(matchingDirectories, id: \.self) { path in
                        Button { cwd = path; onClose() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(path).font(.system(size: 11)).foregroundStyle(.secondary)
                                }.lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if path == cwd { Image(systemName: "checkmark").font(.system(size: 11)) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8).contentShape(Rectangle())
                        }.buttonStyle(WorkbenchDisclosureButtonStyle()).help(path)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: recent.isEmpty ? 64 : 180)
            Divider()
            TextField("项目目录（绝对路径）", text: $directoryDraft)
                .textFieldStyle(.roundedBorder).focused($cwdFocused)
                .onSubmit(applyDirectory)
            HStack {
                if host.isLocal {
                    Button("选择文件夹…", action: chooseLocalDirectory)
                }
                Spacer()
                Button("完成", action: applyDirectory)
                    .disabled(!directoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"))
            }
        }.padding(18).frame(width: 380)
            .onAppear { directoryDraft = cwd; directoryQuery = "" }
    }

    private func applyDirectory() {
        let path = directoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return }
        cwd = path; onClose()
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if cwd.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: cwd) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cwd = url.path; onClose()
    }

}
