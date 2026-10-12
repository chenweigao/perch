import AppKit
import SwiftUI
import WorkbenchCore

extension AgentMarkKind {
    init?(_ kind: SessionKind) {
        self.init(rawValue: kind.rawValue)
    }
}

/// Brand mark for an agent session kind. Draws the shared vector geometry once
/// per render pass — no asset decoding, no template rasterization. Terminal
/// keeps the system glyph; it is not an agent brand.
struct AgentMark: View {
    let kind: SessionKind
    var size: CGFloat = 14

    var body: some View {
        if let mark = AgentMarkKind(kind) {
            Canvas { context, canvasSize in
                context.withCGContext { cg in
                    AgentMarkArtwork.draw(mark, in: CGRect(origin: .zero, size: canvasSize), context: cg)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.92))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// Native menus are NSMenu-backed and only retain color from non-template
/// NSImages (see HostIdentityIcon.menuImage). Menu *labels* also flatten
/// Canvas content to nothing, so menu faces must use this image too.
/// Everywhere else uses the vector view above.
enum AgentMarkMenuImage {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for kind: SessionKind, size: CGFloat = 16) -> Image {
        guard let mark = AgentMarkKind(kind) else { return Image(systemName: kind.symbol) }
        let key = NSString(string: "\(mark.rawValue)-\(size)")
        let nsImage: NSImage
        if let cached = cache.object(forKey: key) {
            nsImage = cached
        } else {
            nsImage = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
                AgentMarkArtwork.draw(mark, in: rect, context: NSGraphicsContext.current!.cgContext)
                return true
            }
            nsImage.isTemplate = false
            cache.setObject(nsImage, forKey: key)
        }
        return Image(nsImage: nsImage).renderingMode(.original)
    }
}
