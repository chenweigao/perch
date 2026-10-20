import AppKit
import ImageIO

/// Serialize native decoding away from the main actor. Cancelled, queued rows
/// exit before decoding; only the view's display-sized bitmap reaches rendering.
/// Shared by transcript attachments and the composer chip. Kept free of
/// WorkbenchCore so scripts/check-composer.sh can compile it standalone.
actor AttachmentImageDecoder {
    static let shared = AttachmentImageDecoder()
    /// Local files read their bytes on this actor, never on the caller's actor.
    func image(url: URL, maxPixels: CGFloat) throws -> NSImage? {
        try Task.checkCancellation()
        return try image(data: Data(contentsOf: url), maxPixels: maxPixels)
    }
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
