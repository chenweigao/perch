import AppKit
import SwiftUI
import Observation
import WorkbenchCore

@MainActor @Observable
final class DocumentReadingState {
    var document: ReadingDocument?
    var notice: String?
    var showOutline = false
    var selectedSection: Int?
    var navigation = 0
    func jump(_ id: Int) { selectedSection = id; navigation += 1; showOutline = false }
}

struct DocumentReaderControls: View {
    let state: DocumentReadingState
    @AppStorage("perch.document.fontSize") private var fontSize = 16.0
    @AppStorage("perch.document.width") private var width = 760.0
    var body: some View {
        Button { state.showOutline.toggle() } label: { Image(systemName: "list.bullet") }
            .help("文档目录").accessibilityLabel("文档目录")
            .popover(isPresented: Binding(get: { state.showOutline }, set: { state.showOutline = $0 })) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text("文档目录").font(.headline)
                        if state.document?.outline.isEmpty != false { Text("本文没有章节标题").foregroundStyle(.secondary) }
                        ForEach(state.document?.outline ?? []) { section in
                            Button { state.jump(section.id) } label: {
                                Text(section.heading ?? "").multilineTextAlignment(.leading)
                                    .padding(.leading, CGFloat(min(4, section.level - 1)) * 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }.frame(width: 300, height: 360)
            }
        Menu {
            Picker("字号", selection: $fontSize) {
                Text("小（14）").tag(14.0); Text("中（16）").tag(16.0)
                Text("大（18）").tag(18.0); Text("特大（20）").tag(20.0)
            }
            Picker("阅读宽度", selection: $width) {
                Text("窄").tag(600.0); Text("标准").tag(760.0); Text("宽").tag(980.0)
            }
        } label: { Image(systemName: "textformat.size") }
            .menuIndicator(.hidden).help("阅读样式").accessibilityLabel("阅读样式")
    }
}

struct DocumentReader: View {
    @Bindable var browser: RemoteFileBrowser
    let text: String
    let path: String
    let onAddContext: ((String) -> Void)?
    let destination: String?
    let onShowDraft: (() -> Void)?
    let onSaveOffset: (Double) -> Void
    @AppStorage("perch.document.fontSize") private var fontSize = 16.0
    @AppStorage("perch.document.width") private var width = 760.0
    @State private var position = ScrollPosition(y: 0)
    @State private var lastOffset: Double?
    @State private var feedback: DocumentFeedback?
    @State private var feedbackText = ""
    @FocusState private var feedbackFocused: Bool
    @State private var added = false
    @State private var showAddedDraft: (() -> Void)?
    @State private var missingAnchor = false
    private var state: DocumentReadingState { browser.reading }
    private var matches: [Int] { state.document?.matchingSections(browser.findQuery) ?? [] }
    private struct DocumentFeedback: Identifiable {
        let id = UUID()
        let path: String
        let chapter: String
        let quote: String
        let destination: String?
        let append: (String) -> Void
        let showDraft: (() -> Void)?
    }
    var body: some View {
        VStack(spacing: 0) {
            if !browser.findQuery.isEmpty {
                Text(matches.isEmpty ? L("未找到匹配段落") : L("\(matches.count) 个匹配段落"))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            if let notice = state.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if missingAnchor { Text("未找到链接中的章节").font(.caption).foregroundStyle(.orange) }
            if added {
                HStack {
                    Text("反馈已加入原会话草稿")
                    Button("查看草稿") { showAddedDraft?() }
                    Button { added = false } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭反馈提示")
                }.font(.caption).padding(6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(state.document?.sections ?? []) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                ReplyBlocks(blocks: section.blocks)
                                    .environment(\.documentFontScale, CGFloat(fontSize / 14))
                                    .environment(\.documentQuery, browser.findQuery)
                                    .environment(\.documentOpenLink, { url in
                                        guard browser.path == path else { return true }
                                        if let target = DocumentLink.target(url) { browser.navigateDocument(target); return true }
                                        if url.scheme == "perch-file", let reference = ConversationFileReference(url: url) {
                                            browser.navigateDocument(reference.path); return true
                                        }
                                        return false
                                    })
                                    .environment(\.documentSelection, onAddContext.map { append in { quote in
                                        feedbackText = ""
                                        feedback = DocumentFeedback(path: path, chapter: section.chapter,
                                            quote: quote, destination: destination, append: append, showDraft: onShowDraft)
                                    } })
                                ForEach(section.images) { image in
                                    DocumentInlineImage(image: image, documentPath: path, host: browser.host,
                                                        open: browser.navigateDocument)
                                }
                            }.id(section.id)
                        }
                    }.padding(24).frame(maxWidth: width).frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, offset in lastOffset = offset }
                .onChange(of: state.navigation) { _, _ in
                    if let id = state.selectedSection { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: browser.documentNavigation) { _, _ in jumpToAnchor(proxy) }
                .onChange(of: browser.findQuery) { _, _ in jumpToMatch(proxy) }
                .onChange(of: browser.findIndex) { _, _ in jumpToMatch(proxy) }
                .task(id: browser.fileRequest?.id) {
                    let source = text
                    guard let parsed = await DocumentParser.shared.parse(source), !Task.isCancelled else { return }
                    state.document = parsed
                    if browser.documentAnchor != nil { jumpToAnchor(proxy) }
                    else { position.scrollTo(y: browser.documents.current?.offset ?? 0) }
                }
                .onDisappear { if let lastOffset { onSaveOffset(lastOffset) } }
            }
        }
        .sheet(item: $feedback) { captured in
            VStack(alignment: .leading, spacing: 14) {
                Text("文档反馈").font(.headline)
                Text(captured.destination ?? "").font(.caption).foregroundStyle(.secondary)
                Text(captured.path).font(.caption).lineLimit(2).truncationMode(.middle)
                ScrollView { Text(captured.quote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 150)
                TextField("希望如何修改？", text: $feedbackText, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).focused($feedbackFocused)
                HStack {
                    Button("取消") { feedback = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("加入原会话草稿") {
                        let section = captured.chapter.isEmpty ? "" : L("\n章节：") + captured.chapter
                        let quote = captured.quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                        captured.append(L("文档：\(captured.path)\(section)\n\n\(quote)\n\n反馈：\(feedbackText)"))
                        showAddedDraft = captured.showDraft; feedback = nil; added = true
                    }.disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }.padding(20).frame(width: 480)
                .background(Color(nsColor: .windowBackgroundColor))
                .task { feedbackFocused = true }
        }
    }
    private func jumpToAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = browser.documentAnchor, let document = state.document else { return }
        let id = anchor.isEmpty ? document.sections.first?.id : document.outline.first { $0.anchor == anchor.lowercased() }?.id
        missingAnchor = id == nil
        if let id { proxy.scrollTo(id, anchor: .top) }
    }
    private func jumpToMatch(_ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        let index = ((browser.findIndex % matches.count) + matches.count) % matches.count
        proxy.scrollTo(matches[index], anchor: .top)
    }
}

private struct DocumentInlineImage: View {
    let image: DocumentImage
    let documentPath: String
    let host: SSHHost?
    let open: (String) -> Void
    @State private var decoded: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let decoded {
                Button { open(image.target) } label: {
                    Image(nsImage: decoded).resizable().scaledToFit().frame(maxHeight: 800)
                }.buttonStyle(.plain).accessibilityLabel(image.alt.isEmpty ? L("打开图片") : image.alt)
            } else if failed {
                Button { open(image.target) } label: { Label(image.alt.isEmpty ? L("打开引用图片") : image.alt, systemImage: "photo") }
                    .font(.caption)
            } else { ProgressView().controlSize(.small) }
        }.task(id: image.target) {
            guard let host, case .file(let path, _) = DocumentLink.resolve(image.target, relativeTo: documentPath) else {
                failed = true; return
            }
            let reader = RemoteReader(local: host.isLocal)
            let result = await withTaskCancellationHandler {
                await reader.run(command: RemoteFileCommand.remoteCommand(path: path, limit: 8 * 1_048_576), destination: host.destination)
            } onCancel: { reader.terminate() }
            guard !Task.isCancelled else { return }
            if let response = try? result.get(), let content = try? RemoteFileCommand.parse(response, limit: 8 * 1_048_576) {
                let size: Int
                switch content { case .binary(let bytes), .text(_, _, let bytes): size = bytes; default: failed = true; return }
                guard size <= 8 * 1_048_576, let data = RemoteFileCommand.body(in: response) else { failed = true; return }
                let value = try? await AttachmentImageDecoder.shared.image(data: data, maxPixels: 2400)
                guard !Task.isCancelled else { return }
                decoded = value
            }
            failed = decoded == nil
        }
    }
}
