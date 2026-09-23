import SwiftUI
import WorkbenchCore

/// Machine identity is independent of connection and task status.
struct HostIdentityIcon: View {
    let hostID: UUID?

    var body: some View {
        Image(systemName: Self.symbol(for: hostID))
            .foregroundStyle(Color(nsColor: Self.color(for: hostID)))
            .accessibilityHidden(true)
    }

    // Native macOS menus need a non-template image to retain the machine color.
    static func menuImage(for hostID: UUID) -> Image {
        let image = NSImage(systemSymbolName: symbol(for: hostID), accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [color(for: hostID)]))!
        image.isTemplate = false
        return Image(nsImage: image).renderingMode(.original)
    }

    private static func symbol(for hostID: UUID?) -> String {
        hostID == ExecutionEnvironment.localHostID ? "desktopcomputer" : "globe"
    }

    private static func color(for hostID: UUID?) -> NSColor {
        guard let hostID, hostID != ExecutionEnvironment.localHostID else { return .secondaryLabelColor }
        // Stable across launches and host renames, unlike hashValue.
        let index = hostID.uuidString.utf8.reduce(0) { ($0 * 31 + Int($1)) % 5 }
        return [.systemOrange, .systemPurple, .systemBlue, .systemTeal, .systemPink][index]
    }
}

struct HostIdentityLabel: View {
    let hostID: UUID
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            HostIdentityIcon(hostID: hostID)
            Text(name).lineLimit(1).truncationMode(.tail)
        }.accessibilityElement(children: .combine)
    }
}
