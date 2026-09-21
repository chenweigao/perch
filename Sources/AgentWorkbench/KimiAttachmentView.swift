import AppKit
import SwiftUI
import WorkbenchCore

struct KimiAttachmentView: View {
    let part: KimiPart
    let api: KimiAPI?
    let sessionId: String
    @State private var image: NSImage?
    @State private var error: String?
    private var fileId: String? { part.source?["file_id"].string ?? part.fileId }
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
        }.task(id: fileId) {
            guard part.type == "image" else { return }
            do {
                if part.source?["kind"].string == "base64", let encoded = part.source?["data"].string, let data = Data(base64Encoded: encoded) { image = NSImage(data: data) }
                else if let fileId, let api { image = NSImage(data: try await api.request(mediaPath(fileId))) }
            } catch { self.error = "图片读取失败：" + error.localizedDescription }
        }
    }
    private func mediaPath(_ id: String) -> String {
        part.source?["kind"].string == "file" || part.type == "file" ? "/api/v1/files/\(id)" : "/api/v1/sessions/\(sessionId)/media/\(id)"
    }
}
