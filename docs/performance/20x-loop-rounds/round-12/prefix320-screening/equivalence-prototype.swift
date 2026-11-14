import Foundation

// ===== round-11 committed collapsedWhitespace (verbatim from /tmp/r11-full.swift logic) =====
extension String {
    var collapsedWhitespace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var contiguous = self
        return contiguous.withUTF8 { bytes in
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var pendingSpace = false
            var lastScalar: UInt32 = 0
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if byte == 0x20 || (0x09...0x0D).contains(byte) {
                    if Self.isPrependScalar(lastScalar) { return strict() }
                    while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) { i += 1 }
                    if i < bytes.count, bytes[i] >= 0x80, Self.beginsBindingMark(in: bytes, at: i) { return strict() }
                    if !out.isEmpty { pendingSpace = true }
                } else if byte < 0x80 {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(byte)
                    lastScalar = 0
                    i += 1
                } else {
                    guard let (scalar, length) = Self.utf8Scalar(in: bytes, at: i),
                          !Self.isNonASCIIWhitespace(scalar) else { return strict() }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    for offset in 0..<length { out.append(bytes[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
    static func isPrependScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2,
             0x0D4E, 0x110BD, 0x110CD, 0x111C2...0x111C3, 0x113D1,
             0x1193F, 0x11941, 0x11A3A, 0x11A84...0x11A89, 0x11D46,
             0x11F02, 0x16D40...0x16D43:
            return true
        default:
            return false
        }
    }
    static func isNonASCIIWhitespace(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
    static func utf8Scalar(in bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> (UInt32, Int)? {
        func continuation(_ j: Int) -> Bool { j < bytes.count && bytes[j] & 0xC0 == 0x80 }
        switch bytes[i] {
        case 0xC2...0xDF:
            guard continuation(i + 1) else { return nil }
            return (UInt32(bytes[i] & 0x1F) << 6 | UInt32(bytes[i + 1] & 0x3F), 2)
        case 0xE0...0xEF:
            guard continuation(i + 1), continuation(i + 2) else { return nil }
            return (UInt32(bytes[i] & 0x0F) << 12 | UInt32(bytes[i + 1] & 0x3F) << 6
                    | UInt32(bytes[i + 2] & 0x3F), 3)
        case 0xF0...0xF4:
            guard continuation(i + 1), continuation(i + 2), continuation(i + 3) else { return nil }
            return (UInt32(bytes[i] & 0x07) << 18 | UInt32(bytes[i + 1] & 0x3F) << 12
                    | UInt32(bytes[i + 2] & 0x3F) << 6 | UInt32(bytes[i + 3] & 0x3F), 4)
        default:
            return nil
        }
    }
    static func isNeverBindingScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x3001...0x3029, 0x3030...0x303E,
             0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FF,
             0x3105...0x312F, 0x3131...0x318E, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFF01...0xFF60, 0xFF61...0xFF9D, 0xFFA0...0xFFDC:
            return true
        default:
            return false
        }
    }
    static func beginsBindingMark(in bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard let (value, _) = utf8Scalar(in: bytes, at: i), let scalar = Unicode.Scalar(value) else { return true }
        if isNeverBindingScalar(value) { return false }
        if value == 0x200D || scalar.properties.isGraphemeExtend { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}

// ===== round-12 candidate helper =====
extension Substring {
    // Collapse on the substring's own bytes; identical semantics to String.collapsedWhitespace.
    var collapsedWhitespaceSub: String {
        let materialized = { String(self).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let result = utf8.withContiguousStorageIfAvailable({ bytes -> String? in
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var pendingSpace = false
            var lastScalar: UInt32 = 0
            var i = 0
            while i < bytes.count {
                let byte = bytes[i]
                if byte == 0x20 || (0x09...0x0D).contains(byte) {
                    if String.isPrependScalar(lastScalar) { return nil }
                    while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) { i += 1 }
                    if i < bytes.count, bytes[i] >= 0x80, String.beginsBindingMark(in: bytes, at: i) { return nil }
                    if !out.isEmpty { pendingSpace = true }
                } else if byte < 0x80 {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(byte)
                    lastScalar = 0
                    i += 1
                } else {
                    guard let (scalar, length) = String.utf8Scalar(in: bytes, at: i),
                          !String.isNonASCIIWhitespace(scalar) else { return nil }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    for offset in 0..<length { out.append(bytes[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            return String(decoding: out, as: UTF8.self)
        }) else { return materialized() }
        return result ?? materialized()
    }
}

func excerptOld(_ text: String) -> String {
    (" " + String(text.prefix(320))).collapsedWhitespace
}

func excerptNew(_ text: String) -> String {
    // Hybrid leading-cluster guard: ASCII and the pinned never-binding ranges
    // (CJK/kana/Hangul/fullwidth — exhaustively proven not to fuse with a
    // preceding space) take the fast path directly; any other non-ASCII leader
    // is probed against the toolchain's own clustering, and a fusing leader
    // keeps the old formula verbatim.
    if let first = text.unicodeScalars.first {
        let v = first.value
        if v >= 0x80, !String.isNeverBindingScalar(v) {
            let head = text.prefix(2)
            if (" " + head).count < head.count + 1 { return excerptOld(text) }
        }
    }
    if text.utf8.count <= 320 { return text.collapsedWhitespace }
    let end = text.index(text.startIndex, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
    return text[text.startIndex..<end].collapsedWhitespaceSub
}

// ===== differential corpus =====
var rng = SystemRandomNumberGenerator()
let atoms = ["a", " ", "  ", "\t", "\r\n", "中", "文", "\u{301}", "\u{200D}", "\u{0600}", "\u{3000}", "\u{A0}", "👨", "🏻", "\u{0E33}", "\u{111C3}", "x", "\n", "English", "　", "\u{903}", "é", "\u{1F3FB}"]
var failures = 0
var checked = 0
func check(_ text: String, _ label: String) {
    checked += 1
    let o = excerptOld(text), n = excerptNew(text)
    if o != n {
        failures += 1
        if failures <= 10 {
            print("FAIL [\(label)] old=\(o.debugDescription) new=\(n.debugDescription) input=\(text.prefix(60).debugDescription)…len=\(text.count)")
        }
    }
}
// structured edge cases
for lead in ["", " ", "\u{301}", "\u{200D}", "\u{0600}", "\u{3000}", "\n", "👨", "\u{0E33}", "\u{111C3}", "\u{1F3FB}", "中"] {
    for body in ["", "a", "abc def", "中文 混排 English words", String(repeating: "字", count: 319), String(repeating: "字", count: 320), String(repeating: "字", count: 321), String(repeating: "ab ", count: 200), "a\u{301}b\u{301}c", "\t\tx  y\r\n"] {
        for tail in ["", " ", "  ", "\u{301}", "\n"] {
            check(lead + body + tail, "edge")
        }
    }
}
// random fuzz
for trial in 0..<30000 {
    var s = ""
    let n = Int.random(in: 0...40, using: &rng)
    for _ in 0..<n { s += atoms[Int.random(in: 0..<atoms.count, using: &rng)] }
    if trial % 3 == 0 { s += String(repeating: "長", count: Int.random(in: 300...340, using: &rng)) }
    check(s, "fuzz\(trial)")
}
print("checked=\(checked) failures=\(failures)")
