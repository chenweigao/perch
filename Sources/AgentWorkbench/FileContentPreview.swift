import AppKit
import PDFKit
import SwiftUI
import WebKit
import WorkbenchCore

struct FileTabStrip: View {
    @Bindable var browser: RemoteFileBrowser
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(browser.documents.tabs) { tab in
                    HStack(spacing: 6) {
                        Button((tab.path as NSString).lastPathComponent) { browser.open(tab.path) }
                            .lineLimit(1).help(tab.path)
                        Button { browser.closeFile(tab.path) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .accessibilityLabel("关闭文件 \((tab.path as NSString).lastPathComponent)")
                    }.buttonStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(tab.path == browser.path ? Color.primary : .secondary)
                        .background(tab.path == browser.path ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.horizontal, 8).padding(.vertical, 3)
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }
}

struct FileDisplayMode: View {
    @Bindable var browser: RemoteFileBrowser
    var body: some View {
        if case .text = browser.content, browser.previewKind != .source {
            Picker("显示", selection: Binding(get: { browser.documents.current?.reading ?? false }, set: { browser.documents.setReading($0) })) {
                Text("阅读").tag(true); Text("源码").tag(false)
            }.pickerStyle(.segmented).frame(width: 100)
        }
    }
}

struct FileFindBar: View {
    @Bindable var browser: RemoteFileBrowser
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            TextField("在已读取内容中查找", text: $browser.findQuery)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { browser.findIndex += 1 }
                .help("匹配定位最多 5000 处")
            Button { browser.findIndex -= 1 } label: { Image(systemName: "chevron.up") }.accessibilityLabel("上一个匹配")
            Button { browser.findIndex += 1 } label: { Image(systemName: "chevron.down") }.accessibilityLabel("下一个匹配")
            Button { isPresented = false; browser.findQuery = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭查找")
        }.font(.system(size: 12)).controlSize(.small).buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .onAppear { browser.documents.setReading(false); focused = true }
            .onChange(of: browser.findQuery) { _, _ in browser.findIndex = 0 }
    }
}

struct FileContentPreview: View {
    let kind: FilePreviewKind
    let text: String
    let data: Data?
    let revision: UUID?
    let path: String
    var initialOffset: Double? = nil
    var onSaveOffset: ((Double) -> Void)? = nil
    @State private var position = ScrollPosition(y: 0)
    @State private var lastOffset: Double?
    @State private var image: NSImage?
    @State private var imageError = false
    var body: some View {
        Group {
            switch kind {
            case .markdown:
                ScrollView { KimiMarkdown(text: text).padding(20).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity) }
                    .scrollPosition($position)
                    .onAppear { position.scrollTo(y: initialOffset ?? 0) }
                    .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.y) } action: { _, offset in lastOffset = offset }
                    .onDisappear { if let lastOffset { onSaveOffset?(lastOffset) } }
            case .table: DelimitedFileView(text: text, delimiter: path.hasSuffix(".tsv") ? "\t" : ",")
            case .html:
                VStack(alignment: .leading, spacing: 0) {
                    Text("独立 HTML 预览 · 仅内联资源，网络访问已关闭").font(.caption).foregroundStyle(.secondary).padding(8)
                    SandboxedHTMLPreview(source: text)
                }
            case .pdf:
                if let data { PDFFilePreview(data: data) }
            case .image:
                if let image {
                    ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 1600, maxHeight: 1600).padding(16) }
                } else if imageError { ContentUnavailableView("无法解码图片", systemImage: "photo") }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            case .source: EmptyView()
            }
        }.task(id: revision) {
            guard kind == .image, let data else { return }
            image = nil; imageError = false
            let decoded = try? await AttachmentImageDecoder.shared.image(data: data, maxPixels: 3200)
            guard !Task.isCancelled else { return }
            image = decoded; imageError = decoded == nil
        }
    }
}

private struct DelimitedFileView: View {
    let text: String
    let delimiter: Character
    var body: some View {
        let preview = DelimitedPreview(text, delimiter: delimiter)
        VStack(alignment: .leading) {
            Text(preview.truncated ? "显示前 200 行、40 列；完整内容可在源码中查看" : "\(preview.rows.count) 行")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).textSelection(.enabled).font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                                    .lineLimit(8).frame(width: 180, alignment: .leading).padding(8)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

private struct PDFFilePreview: NSViewRepresentable {
    let data: Data
    final class Coordinator { var data: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data; view.document = PDFDocument(data: data)
        view.subviews.filter { $0.identifier?.rawValue == "invalid-pdf" }.forEach { $0.removeFromSuperview() }
        if view.document == nil {
            let label = NSTextField(labelWithString: L("无法解码 PDF"))
            label.identifier = NSUserInterfaceItemIdentifier("invalid-pdf"); label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
    }
}

/// WKWebView is used here for explicit navigation policy and a nonpersistent
/// process. A generated report may run inline interaction, but cannot fetch,
/// navigate, submit a form or gain access to the host filesystem.
private struct SandboxedHTMLPreview: NSViewRepresentable {
    let source: String
    final class Coordinator: NSObject, WKNavigationDelegate {
        var source: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.source != source else { return }
        context.coordinator.source = source
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; form-action 'none'; frame-src 'none'; base-uri 'none'"
        view.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + source, baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
}

enum SourceHighlight {
    static func attributed(_ text: String, path: String, base: NSAttributedString) -> NSAttributedString {
        let extensions = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp", "json", "sh", "yaml", "yml"]
        guard extensions.contains((path as NSString).pathExtension.lowercased()), text.utf8.count <= 256_000 else { return base }
        let result = NSMutableAttributedString(attributedString: base)
        let rules: [(String, NSColor)] = [
            (#"\b(?:let|var|func|class|struct|enum|import|return|if|else|for|while|guard|async|await|def|from|const|function|export|pub|fn|package|type|true|false|null|nil|None)\b"#, .systemPurple),
            (#"\b\d+(?:\.\d+)?\b"#, .systemOrange),
            (#"\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'"#, .systemRed),
            (#"(?m)//[^\n]*|^[ \t]*#[^\n]*"#, .secondaryLabelColor)
        ]
        for (pattern, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)) {
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        return result
    }
}
