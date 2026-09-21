import SwiftUI
import WorkbenchCore

/// Pending text stays in the transcript at full length until the runtime echoes it.
struct PendingMessageContent: View {
    let text: String
    let status: String
    var mode: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let mode { Text(L(key: mode)) }
                Text(L(key: status)).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
