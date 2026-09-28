import AppKit
import SwiftUI
import WorkbenchCore

@MainActor
final class ProjectFileSuggestions: ObservableObject {
    @Published private(set) var catalog: ProjectFileCatalog?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var reader: RemoteReader?
    private var generation = 0

    func cancel() { generation += 1; reader?.terminate(); reader = nil; loading = false }

    func load(host: SSHHost, cwd: String) {
        cancel(); catalog = nil; error = nil
        do { if !host.isLocal { try SSHCommand.validateDestination(host.destination) } }
        catch { self.error = error.localizedDescription; return }
        loading = true
        let token = generation, reader = RemoteReader(local: host.isLocal)
        self.reader = reader
        Task { [weak self] in
            let result = await reader.run(command: ProjectFileCatalog.command(directory: cwd), destination: host.destination)
            guard let self, self.generation == token else { return }
            self.loading = false; self.reader = nil
            do { self.catalog = try ProjectFileCatalog.parse(result.get()) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// References remain plain draft text, so draft persistence and queueing retain
/// them without another attachment store. Listing paths never reads file bodies.
struct ProjectMessageComposer: View {
    @Binding var text: String
    let host: SSHHost
    let cwd: String
    let placeholder: String
    let accessibilityLabel: String
    let canSend: Bool
    let onSend: () -> Void
    var onFiles: (([URL]) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    var onKey: ((ComposerKey) -> Bool)? = nil
    @StateObject var files = ProjectFileSuggestions()
    @State private var queryRange: NSRange?
    @State private var query = ""
    @State private var choice = 0
    @State private var nextSelection: NSRange?
    private var matches: [String] { files.catalog?.matches(query) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if queryRange != nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("引用项目文件").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button("刷新") { choice = 0; files.load(host: host, cwd: cwd) }
                        Button("关闭") { dismiss() }
                    }.font(.system(size: 11))
                    if files.loading { ProgressView().controlSize(.small) }
                    else if let error = files.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    else if matches.isEmpty { Text("没有匹配文件").font(.caption).foregroundStyle(.secondary) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(matches.enumerated()), id: \.element) { index, path in
                                        Button { choose(path) } label: {
                                            Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 23).padding(.horizontal, 5)
                                                .background(index == choice ? Color.primary.opacity(0.07) : .clear)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).help(path).id(index)
                                    }
                                }
                            }.frame(height: CGFloat(min(150, matches.count * 25 - 2)))
                                .onChange(of: choice) { _, value in proxy.scrollTo(value) }
                        }
                    }
                    Text("↑↓ 选择 · Return / Tab 引用 · Esc 关闭，不会发送消息")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(8).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
            let references = ProjectFileReference.references(in: text)
            if !references.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                            HStack(spacing: 4) {
                                Button {
                                    var url = URLComponents(); url.scheme = "perch-file"
                                    url.queryItems = [URLQueryItem(name: "path", value: reference.path)]
                                    NotificationCenter.default.post(name: .init("PerchOpenConversationFile"), object: url.url)
                                } label: {
                                    Label((reference.path as NSString).lastPathComponent, systemImage: "doc.text")
                                        .lineLimit(1)
                                }.help(reference.path)
                                Button { remove(reference) } label: { Image(systemName: "xmark.circle.fill") }
                                    .help("移除文件引用")
                            }.font(.system(size: 11)).buttonStyle(.plain).padding(5)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            MessageComposer(text: $text, placeholder: placeholder, accessibilityLabel: accessibilityLabel,
                canSend: canSend, onSend: onSend, onFiles: onFiles, onError: onError,
                onKey: handle, onEditSelection: editSelection, selectionAfterReplacement: nextSelection)
        }
        .onChange(of: cwd) { _, _ in dismiss() }
        .onChange(of: host.id) { _, _ in dismiss() }
        .onDisappear { dismiss() }
    }

    private func editSelection(_ draft: String, _ selection: NSRange) {
        guard draft == text else { return }
        nextSelection = nil
        guard let value = ProjectFileReference.query(in: draft, selection: selection) else { dismiss(); return }
        let opened = queryRange == nil
        if queryRange != value.range || query != value.filter { choice = 0 }
        queryRange = value.range; query = value.filter
        if opened { files.load(host: host, cwd: cwd) }
    }

    private func dismiss() { queryRange = nil; choice = 0; files.cancel() }

    private func handle(_ key: ComposerKey) -> Bool {
        guard queryRange != nil else { return onKey?(key) ?? false }
        switch key {
        case .up: choice = max(0, choice - 1)
        case .down: choice = min(max(0, matches.count - 1), choice + 1)
        case .enter, .tab:
            if matches.indices.contains(choice) { choose(matches[choice]) }
        case .escape: dismiss()
        }
        // Even an empty/loading list owns Return: completing a file must not send.
        return true
    }

    private func choose(_ path: String) {
        guard let range = queryRange, let root = files.catalog?.root, NSMaxRange(range) <= (text as NSString).length else { return }
        let token = ProjectFileReference.token(path: RemoteFilePath.child(root, path)) + " "
        nextSelection = NSRange(location: range.location + (token as NSString).length, length: 0)
        text = (text as NSString).replacingCharacters(in: range, with: token)
        dismiss()
        NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
    }

    private func remove(_ reference: ProjectFileReference) {
        nextSelection = NSRange(location: reference.range.location, length: 0)
        text = (text as NSString).replacingCharacters(in: reference.range, with: "")
        dismiss()
        NotificationCenter.default.post(name: .init("PerchFocusComposer"), object: nil)
    }
}
