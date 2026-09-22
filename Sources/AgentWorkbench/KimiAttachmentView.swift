import AppKit
import ImageIO
import SwiftUI
import WorkbenchCore

struct KimiAttachmentView: View {
    let part: KimiPart
    let api: KimiAPI?
    let sessionId: String
    @State private var image: NSImage?
    @State private var error: String?
    @Environment(\.displayScale) private var displayScale
    private var fileId: String? { part.source?["file_id"].string ?? part.fileId }
    private struct ImageRequest: Equatable {
        let fileId: String?
        let scale: CGFloat
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340).frame(maxWidth: 600, alignment: .leading) }
            HStack {
                Label(part.name ?? (part.type == "image" ? "图片附件" : "文件附件"), systemImage: part.type == "image" ? "photo" : "doc").font(.system(size: 12))
                if let fileId, let api {
                    Button("存储附件") {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = part.name ?? fileId
                        if panel.runModal() == .OK, let url = panel.url {
                            Task {
                                do { try await api.request(mediaPath(fileId)).write(to: url, options: .atomic) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }.controlSize(.small)
                }
            }.foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
        }.task(id: ImageRequest(fileId: fileId, scale: displayScale)) {
            guard part.type == "image" else { return }
            do {
                let data: Data
                if part.source?["kind"].string == "base64", let encoded = part.source?["data"].string, let decoded = Data(base64Encoded: encoded) { data = decoded }
                else if let fileId, let api { data = try await api.request(mediaPath(fileId)) }
                else { return }
                let decoded = try await AttachmentImageDecoder.shared.image(data: data, maxPixels: 600 * displayScale)
                try Task.checkCancellation()
                image = decoded
            } catch is CancellationError {
                // Leaving history or switching sessions must not publish stale images.
            } catch { self.error = "图片读取失败：" + error.localizedDescription }
        }
    }
    private func mediaPath(_ id: String) -> String {
        part.source?["kind"].string == "file" || part.type == "file" ? "/api/v1/files/\(id)" : "/api/v1/sessions/\(sessionId)/media/\(id)"
    }
}

/// Serialize native decoding away from the main actor. Cancelled, queued rows
/// exit before decoding; only the view's display-sized bitmap reaches rendering.
actor AttachmentImageDecoder {
    static let shared = AttachmentImageDecoder()
    func image(data: Data, maxPixels: CGFloat) throws -> NSImage? {
        try Task.checkCancellation()
        #if TRANSCRIPT_CHECKS
        precondition(!Thread.isMainThread, "Attachment decoding ran on the main thread")
        #endif
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else {
            // Keep NSImage's existing handling of vector and multi-frame formats.
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap, size: .zero)
    }
}
