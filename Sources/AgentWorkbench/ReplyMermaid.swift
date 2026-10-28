import AppKit
import CryptoKit
import SwiftUI
import WebKit
import WorkbenchCore

/// ```` ```mermaid ```` fenced blocks settle into a rasterized diagram. Detection is a
/// language check at render time; everything else (parsing, caching, reveal) is untouched.
enum MermaidSupport {
    static func isMermaid(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespaces).lowercased() == "mermaid"
    }
}

/// Mermaid diagrams are rendered by the bundled mermaid.js in one shared offscreen
/// web view, then rasterized to a PNG — the transcript itself only ever hosts static
/// images, so scrolling and row reuse stay as cheap as any other image. Renders are
/// serialized through a single queue, coalesced by (source, appearance), cached in
/// memory and on disk, and bounded in size; failures fall back to the code card.
@MainActor
final class MermaidRenderer {
    struct Diagram {
        /// Point size matches the diagram's natural size; the bitmap is 2x.
        let image: NSImage
        let png: Data
    }

    static let shared = MermaidRenderer()

    /// Past these caps the bitmap cost stops being proportional to its reading size;
    /// the block falls back to the code card instead.
    static let maxSourceLength = 100_000
    static let maxDimension: Double = 3_000
    static let maxArea: Double = 4_000_000

    private struct Key: Hashable {
        let digest: String
        let dark: Bool
    }

    private var memory: [Key: Diagram] = [:]
    private var memoryOrder: [Key] = []
    /// Byte-budgeted: a 3000pt diagram costs a hundred times a small one.
    private var memoryBytes = 0
    private static let maxMemoryEntries = 64
    private static let maxMemoryBytes = 48 * 1024 * 1024
    private var failed: Set<Key> = []
    private var inFlight: [Key: Task<Diagram?, Never>] = [:]
    /// Renders serialize on the one web view; each task awaits its predecessor.
    private var tail: Task<Diagram?, Never>?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var webViewReady = false
    private var idleTeardown: Task<Void, Never>?

    func diagram(source: String, dark: Bool) async -> Diagram? {
        guard !source.isEmpty, source.utf8.count <= Self.maxSourceLength else { return nil }
        let key = Key(digest: Self.digest(source), dark: dark)
        if let hit = memory[key] {
            touch(key)
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("mermaid_memory_hit")
            #endif
            return hit
        }
        if failed.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.produce(key: key, source: source)
        }
        tail = task
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    private func produce(key: Key, source: String) async -> Diagram? {
        idleTeardown?.cancel()
        defer { scheduleIdleTeardown() }
        if let disk = loadDisk(key) {
            storeMemory(key, disk)
            #if TRANSCRIPT_CHECKS
            NavigationRenderMetrics.count("mermaid_disk_hit")
            #endif
            return disk
        }
        #if TRANSCRIPT_CHECKS
        let start = CACurrentMediaTime()
        defer { NavigationRenderMetrics.record("mermaid_render", since: start) }
        #endif
        // Spans the web view's awaits: aggregated, but kept out of frame
        // attribution. Its main-thread steps are journaled on their own.
        let perfProbe = PerfDiagnostics.begin()
        defer { PerfDiagnostics.end("mermaid_render", perfProbe, journal: false) }
        guard await ensureReady(), let webView else { return nil }
        guard let report = await evaluate(webView, source: source, dark: key.dark) else {
            // Timeout or a wedged page: reload to a known state for the next job.
            webViewReady = false
            webView.reload()
            failed.insert(key)
            return nil
        }
        guard report.error == nil,
              let width = report.width, let height = report.height,
              width > 0, height > 0,
              width <= Self.maxDimension, height <= Self.maxDimension,
              width * height <= Self.maxArea else {
            failed.insert(key)
            return nil
        }
        let size = NSSize(width: ceil(width), height: ceil(height))
        // The web view is the window's content view; resize the window itself.
        window?.setContentSize(size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.snapshotWidth = NSNumber(value: Int(size.width * 2))
        guard let snapshot = try? await webView.takeSnapshot(configuration: configuration),
              let pixels = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            failed.insert(key)
            return nil
        }
        // takeSnapshot hands back a CGImage-backed rep; rewrap it as a bitmap
        // at 2x pixels with the point size as its logical size.
        let encodeProbe = PerfDiagnostics.begin()
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        bitmap.size = size
        let encoded = bitmap.representation(using: .png, properties: [:])
        PerfDiagnostics.end("mermaid_encode", encodeProbe,
                            detail: "pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) bytes=\(encoded?.count ?? 0)")
        guard let png = encoded else {
            failed.insert(key)
            return nil
        }
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let diagram = Diagram(image: image, png: png)
        storeMemory(key, diagram)
        storeDisk(key, png: png)
        return diagram
    }

    private struct RenderReport {
        let width: Double?
        let height: Double?
        let error: String?
    }

    private func evaluate(_ webView: WKWebView, source: String, dark: Bool) async -> RenderReport? {
        let raw = await withTimeout(15) { @MainActor in
            try await webView.callAsyncJavaScript(
                "return await window.__perchRenderMermaid(source, dark);",
                arguments: ["source": source, "dark": dark],
                contentWorld: .page)
        }
        guard let object = raw as? [String: Any] else { return nil }
        return RenderReport(width: (object["width"] as? NSNumber)?.doubleValue,
                            height: (object["height"] as? NSNumber)?.doubleValue,
                            error: object["error"] as? String)
    }

    private func withTimeout<T: Sendable>(_ seconds: Double,
                                          _ work: @escaping @MainActor () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { @MainActor in try? await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Web view lifecycle

    private func ensureReady() async -> Bool {
        if webViewReady { return true }
        guard let script = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let mermaidJS = try? String(contentsOf: script, encoding: .utf8) else { return false }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
            // An ordered-in but offscreen window keeps the web content process
            // painting (snapshots of never-shown windows come back blank), while
            // the view itself stays out of the transcript's view hierarchy.
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 64, height: 64),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderBack(nil)
            self.window = window
            self.webView = view
        }
        guard let webView else { return false }
        // The library is inlined: a file base URL cannot load subresource scripts.
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html, body { margin: 0; padding: 0; background: transparent; }
        #host { display: inline-block; }</style>
        <script>
        """ + mermaidJS + """
        </script>
        </head><body><div id="host"></div>
        <script>
        window.__perchRenderMermaid = async function(source, dark) {
          const host = document.getElementById('host');
          host.textContent = '';
          try {
            document.body.style.background = dark ? '#1c1c1e' : '#ffffff';
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'strict',
              theme: dark ? 'dark' : 'default',
              fontFamily: '-apple-system, "PingFang SC", "Helvetica Neue", sans-serif'
            });
            const id = 'perch-mermaid';
            document.getElementById(id)?.remove();
            const output = await mermaid.render(id, source);
            host.innerHTML = output.svg;
            const svg = host.querySelector('svg');
            if (!svg) { return { width: 0, height: 0, error: 'no svg' }; }
            let width = 0, height = 0;
            const viewBox = svg.viewBox && svg.viewBox.baseVal;
            if (viewBox && viewBox.width > 0) { width = viewBox.width; height = viewBox.height; }
            if (!width || !height) { const box = svg.getBBox(); width = box.width; height = box.height; }
            if (!width || !height) { return { width: 0, height: 0, error: 'empty diagram' }; }
            svg.style.maxWidth = 'none';
            svg.setAttribute('width', String(width));
            svg.setAttribute('height', String(height));
            return { width: Math.ceil(width), height: Math.ceil(height), error: null };
          } catch (error) {
            host.textContent = '';
            document.querySelectorAll('[id^="perch-mermaid"]').forEach(node => node.remove());
            return { width: 0, height: 0, error: String((error && error.message) || error) };
          }
        };
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: script.deletingLastPathComponent())
        for _ in 0..<200 {
            if let ready = try? await webView.evaluateJavaScript(
                "typeof window.__perchRenderMermaid === 'function'") as? Bool, ready {
                webViewReady = true
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        return false
    }

    /// The web view's processes are the only standing cost; release them once
    /// diagrams have been quiet for ten minutes. The next render reloads on demand.
    private func scheduleIdleTeardown() {
        idleTeardown = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled, let self else { return }
            self.window?.orderOut(nil)
            self.window?.contentView = nil
            self.webView = nil
            self.window = nil
            self.webViewReady = false
        }
    }

    // MARK: Prewarm

    /// A freshly settled reply pre-renders its diagrams so scrolling to them is
    /// instant. The fence scan is textual, not a Markdown parse: a false positive
    /// just renders and caches a diagram nobody views, bounded by the usual caps.
    static let maxPrewarmPerMessage = 4

    func prewarmSources(in text: String, dark: Bool) {
        guard text.contains("```") else { return }
        var sources: [String] = []
        var rest = text[...]
        while let open = rest.range(of: "```"), sources.count < Self.maxPrewarmPerMessage {
            let afterOpen = rest[open.upperBound...]
            guard let fenceEnd = afterOpen.firstIndex(of: "\n") else { break }
            let language = afterOpen[..<fenceEnd].trimmingCharacters(in: .whitespaces)
            guard MermaidSupport.isMermaid(language),
                  let close = afterOpen[fenceEnd...].range(of: "\n```") else {
                rest = afterOpen
                continue
            }
            let source = String(afterOpen[afterOpen.index(after: fenceEnd)..<close.lowerBound])
            sources.append(source)
            rest = afterOpen[close.upperBound...]
        }
        for source in sources {
            Task { @MainActor in _ = await self.diagram(source: source, dark: dark) }
        }
    }

    // MARK: Caches

    private func touch(_ key: Key) {
        if let index = memoryOrder.firstIndex(of: key) {
            memoryOrder.append(memoryOrder.remove(at: index))
        }
    }

    private func storeMemory(_ key: Key, _ diagram: Diagram) {
        // A single diagram bigger than the budget is served but never cached.
        guard diagram.png.count <= Self.maxMemoryBytes else { return }
        if memory[key] == nil { memoryOrder.append(key) }
        memory[key] = diagram
        memoryBytes += diagram.png.count
        while memoryOrder.count > Self.maxMemoryEntries || memoryBytes > Self.maxMemoryBytes {
            let oldest = memoryOrder.removeFirst()
            if let evicted = memory.removeValue(forKey: oldest) { memoryBytes -= evicted.png.count }
        }
    }

    private static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.agentworkbench.mac", isDirectory: true)
            .appendingPathComponent("mermaid", isDirectory: true)
    }

    private static func cacheURL(_ key: Key) -> URL? {
        cacheDirectory()?.appendingPathComponent(key.digest + (key.dark ? "-dark" : "-light") + ".png")
    }

    private func loadDisk(_ key: Key) -> Diagram? {
        // A synchronous read and PNG decode on the main actor.
        let loadProbe = PerfDiagnostics.begin()
        var bytes = 0
        defer { PerfDiagnostics.end("mermaid_disk_load", loadProbe, detail: "bytes=\(bytes)") }
        guard let url = Self.cacheURL(key), let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data) else { return nil }
        bytes = data.count
        // The PNG is 2x; restore the point size it was rendered at.
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide / 2, height: bitmap.pixelsHigh / 2))
        image.addRepresentation(bitmap)
        return Diagram(image: image, png: data)
    }

    private func storeDisk(_ key: Key, png: Data) {
        guard let url = Self.cacheURL(key) else { return }
        Task.detached(priority: .utility) {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
            Self.trimDiskCache(directory)
        }
    }

    /// Bound the on-disk cache independently of history length.
    private nonisolated static func trimDiskCache(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        guard files.count > 256 else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (file, _) in dated.prefix(files.count - 256) {
            try? FileManager.default.removeItem(at: file)
        }
    }

}

/// A settled mermaid block: the diagram card with a source toggle. While the
/// render is in flight (or if it fails) the plain code card shows instead, so
/// streaming text never waits on the renderer.
struct ReplyMermaid: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var diagram: MermaidRenderer.Diagram?
    @State private var failed = false
    @State private var showsSource = false

    private struct RenderRequest: Hashable {
        let source: String
        let dark: Bool
    }
    private var request: RenderRequest { RenderRequest(source: source, dark: colorScheme == .dark) }

    var body: some View {
        Group {
            if let diagram, !showsSource {
                card(showsSource: false) {
                    Image(nsImage: diagram.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(diagram.image.size.width, ReplyStyle.readingWidth), alignment: .leading)
                        .padding(ReplyStyle.Code.inset)
                        .onTapGesture { ImagePreviewPanel.show(data: diagram.png, name: "mermaid.png") }
                        .pointerStyle(.link)
                        .accessibilityLabel("Mermaid 图表")
                }
            } else if diagram != nil {
                card(showsSource: true) { ReplyCodeBody(source: source) }
            } else {
                // Loading and failed states both look like a plain code card.
                ReplyCode(language: "mermaid", source: source)
            }
        }
        // The debounce keeps a growing (streaming) source from rendering on every
        // token: the task restarts on each change and only fires once stable.
        .task(id: request) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if let result = await MermaidRenderer.shared.diagram(source: source, dark: request.dark) {
                diagram = result
                failed = false
            } else {
                failed = true
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(showsSource: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("mermaid").font(.system(size: ReplyStyle.Code.labelSize, weight: .medium)) // l10n-ignore
                    .foregroundStyle(.secondary)
                Spacer()
                Button { self.showsSource = !showsSource } label: {
                    Image(systemName: showsSource ? "flowchart" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: ReplyStyle.captionSize))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(showsSource ? "查看图表" : "查看源码")
                .accessibilityLabel(showsSource ? "查看图表" : "查看源码")
                ReplyCopyButton(text: source, label: "复制代码")
            }
            .padding(.horizontal, ReplyStyle.Code.headerHorizontalPadding)
            .padding(.vertical, ReplyStyle.Code.headerVerticalPadding)
            Rectangle().fill(.primary.opacity(0.055)).frame(height: 1)
            content()
        }
        .background(ReplyStyle.paper, in: RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: ReplyStyle.Code.cornerRadius).strokeBorder(.primary.opacity(0.055)))
    }
}
