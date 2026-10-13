import Foundation

/// Semantic version helpers for the update check. Tag names look like
/// `v0.1.0`; comparison is component-wise numeric with missing parts as zero.
public enum AppVersionCheck {
    /// The greatest stable release version; prereleases are not stable updates.
    public static func latestTag(_ names: [String]) -> String? {
        names.compactMap(parse).max { compare($0.version, $1.version) == .orderedAscending }?.version
    }

    /// Returns the normalized version (without a leading v) for parseable names.
    static func parse(_ name: String) -> (version: String, components: [Int])? {
        var value = name
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        guard !value.contains("-") else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard (2...3).contains(parts.count), numbers.count == parts.count,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return (value, numbers)
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            var v = value
            if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
            if let dash = v.firstIndex(of: "-") { v = String(v[..<dash]) }
            let parsed = v.split(separator: ".").map { Int($0) ?? 0 }
            return parsed + Array(repeating: 0, count: max(0, 3 - parsed.count))
        }
        let left = parts(a), right = parts(b)
        for index in 0..<3 where left[index] != right[index] {
            return left[index] < right[index] ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }
}
