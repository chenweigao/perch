import Foundation

/// Local reading state for one host, worktree and comparison target. Git object
/// identities cover both sides and file modes, without loading every file's diff.
public struct GitReviewProgress: Codable, Equatable, Sendable {
    public private(set) var versions: [String: String] = [:]
    public private(set) var reviewed: [String: String] = [:]
    public private(set) var changed: Set<String> = []
    public var lastPath: String?
    public var offsets: [String: Double] = [:]

    public init() {}

    public mutating func reconcile(_ current: [String: String]) {
        for (path, version) in current where versions[path] != nil && versions[path] != version {
            changed.insert(path)
            offsets.removeValue(forKey: path)
        }
        changed = changed.intersection(current.keys)
        reviewed = reviewed.filter { current[$0.key] == $0.value }
        offsets = offsets.filter { current[$0.key] != nil }
        if let path = lastPath, current[path] == nil { lastPath = nil }
        versions = current
    }

    public func isReviewed(_ path: String) -> Bool {
        guard let version = versions[path] else { return false }
        return reviewed[path] == version
    }

    public mutating func toggleReviewed(_ path: String) {
        guard let version = versions[path] else { return }
        if isReviewed(path) { reviewed.removeValue(forKey: path) }
        else { reviewed[path] = version; changed.remove(path) }
    }
}
