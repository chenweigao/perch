import Foundation
public struct TaskLaunchDefaults: Codable, Equatable {
    public var hostID: UUID
    public var provider: SessionKind
    public var directory: String
    public var model: String
    public init(hostID: UUID, provider: SessionKind, directory: String, model: String) {
        self.hostID = hostID; self.provider = provider; self.directory = directory; self.model = model
    }
}
