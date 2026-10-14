import Foundation

/// Link scheme allowlist for model output (ccgui urlTransform parity): model
/// text must not smuggle local-file or script URLs into clickable links.
public enum SafeLink {
    /// perch-file is Perch's own conversation file reference scheme.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto", "perch-file"]

    public static func allowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
