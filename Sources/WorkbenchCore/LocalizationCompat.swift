#if !canImport(Darwin)
import Foundation

extension String {
    /// Linux Foundation has no localization value machinery. The checks and
    /// bench binaries carry no resource tables on any platform, where the
    /// Apple `String(localized:)` path also falls back to the key itself, so
    /// the shim resolves to the key with interpolated values spliced in.
    public struct LocalizationValue: @unchecked Sendable {
        public enum Part {
            case literal(String)
            case value(Any)
        }
        public let parts: [Part]
        public init(_ key: String) { parts = [.literal(key)] }
        var resolved: String {
            var out = ""
            for part in parts {
                switch part {
                case .literal(let text): out += text
                case .value(let value): out += String(describing: value)
                }
            }
            return out
        }
    }
}

extension String.LocalizationValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

extension String.LocalizationValue: ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        var parts: [String.LocalizationValue.Part] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { parts.append(.literal(literal)) }
        public mutating func appendInterpolation<T>(_ value: T) { parts.append(.value(value)) }
    }
    public init(stringInterpolation: StringInterpolation) { parts = stringInterpolation.parts }
}
#endif
