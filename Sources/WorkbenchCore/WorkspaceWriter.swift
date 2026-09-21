import Foundation

/// Keep atomic filesystem writes ordered and off the UI thread; flush before exit.
public final class WorkspaceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.agentworkbench.workspace-save")
    private let url: URL
    public init(url: URL) { self.url = url }
    public func save(_ workspace: LocalWorkspace, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do { try WorkspaceFile.save(workspace, to: self.url); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    public func flush(_ workspace: LocalWorkspace) throws {
        try queue.sync { try WorkspaceFile.save(workspace, to: url) }
    }
}
