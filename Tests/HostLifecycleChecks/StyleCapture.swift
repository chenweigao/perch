import AppKit
import SwiftUI

extension View {
    @ViewBuilder func styleCaptureContainer() -> some View {
        if StyleCapture.isRequested { containerBackground(Color.clear, for: .window) }
        else { self }
    }
}

enum StyleCapture {
    static var isRequested: Bool { outputPath != nil }
    static var colorScheme: ColorScheme {
        environment["PERCH_STYLE_DARK"] == "1" || environment["CITE_PREVIEW_DARK"] == "1" ? .dark : .light
    }
    static var locale: Locale { Locale(identifier: environment["PERCH_STYLE_LOCALE"] ?? "zh-Hans") }
    static var dynamicTypeSize: DynamicTypeSize { environment["PERCH_STYLE_LARGE_TYPE"] == "1" ? .xxxLarge : .large }
    static var scenario: String { environment["PERCH_STYLE_SCENARIO"] ?? "conversation" }

    static func schedule(contentSize: NSSize) {
        guard outputPath != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                fail("No visible preview window")
            }
            present(window, contentSize: contentSize)
        }
    }

    static func present(_ window: NSWindow, contentSize: NSSize) {
        guard let outputPath else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(nil)
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        CGWarpMouseCursorPosition(CGPoint(x: 0, y: 0))
        window.styleMask = window.styleMask.union(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(contentSize)
        window.setFrameOrigin(NSPoint(x: 48, y: 72))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + (scenario == "scroll" ? 3 : 1)) {
            let metadata: [String: Any] = [
                "window_number": window.windowNumber,
                "window_frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
                "content_bounds": [window.contentView?.bounds.minX ?? 0, window.contentView?.bounds.minY ?? 0,
                                   window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0],
                "backing_scale": window.backingScaleFactor,
                "appearance": window.effectiveAppearance.name.rawValue,
                "dark": colorScheme == .dark,
                "effective_dark": window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                "locale": locale.identifier,
                "large_type": dynamicTypeSize == .xxxLarge,
            ]
            do {
                let output = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outputPath + ".ready.json"), options: .atomic)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var outputPath: String? { environment["PERCH_STYLE_CAPTURE"] }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Style capture failed: \(message)\n".utf8))
        exit(1)
    }
}
