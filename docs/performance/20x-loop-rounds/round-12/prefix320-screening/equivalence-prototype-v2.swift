import Foundation

// ===== shared byte-path machinery (round-11 committed state) =====
struct BytePath {
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
    /// Collapse byte path. `scalarCap`: when non-nil, abort (nil) as soon as the
    /// decoded scalar count exceeds the cap; `bailIsNil` strict triggers also return nil.
    static func collapse(_ bytes: UnsafeBufferPointer<UInt8>, scalarCap: Int?) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var pendingSpace = false
        var lastScalar: UInt32 = 0
        var scalars = 0
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x20 || (0x09...0x0D).contains(byte) {
                if isPrependScalar(lastScalar) { return nil }
                while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) {
                    i += 1
                    scalars += 1
                    if let cap = scalarCap, scalars > cap { return nil }
                }
                if i < bytes.count, bytes[i] >= 0x80, beginsBindingMark(in: bytes, at: i) { return nil }
                if !out.isEmpty { pendingSpace = true }
            } else if byte < 0x80 {
                if pendingSpace { out.append(0x20); pendingSpace = false }
                out.append(byte)
                lastScalar = 0
                i += 1
                scalars += 1
                if let cap = scalarCap, scalars > cap { return nil }
            } else {
                guard let (scalar, length) = utf8Scalar(in: bytes, at: i),
                      !isNonASCIIWhitespace(scalar) else { return nil }
                if pendingSpace { out.append(0x20); pendingSpace = false }
                for offset in 0..<length { out.append(bytes[i + offset]) }
                lastScalar = scalar
                i += length
                scalars += 1
                if let cap = scalarCap, scalars > cap { return nil }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

extension String {
    var collapsedWhitespace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var contiguous = self
        let fast: String? = contiguous.withUTF8 { BytePath.collapse($0, scalarCap: nil) }
        return fast ?? strict()
    }
}
extension Substring {
    var collapsedInPlace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let fast = utf8.withContiguousStorageIfAvailable({ BytePath.collapse($0, scalarCap: nil) }) else { return strict() }
        return fast ?? strict()
    }
}

func excerptOld(_ text: String) -> String {
    (" " + String(text.prefix(320))).collapsedWhitespace
}

/// Round-12 candidate v2: fused scalar-capped collapse, then substring fallback.
func excerptNew(_ text: String) -> String {
    // Leader that fuses with the prepended space keeps the old formula verbatim.
    if let first = text.unicodeScalars.first {
        let v = first.value
        if v >= 0x80, !BytePath.isNeverBindingScalar(v) {
            let head = text.prefix(2)
            if (" " + head).count < head.count + 1 { return excerptOld(text) }
        }
    }
    // Sound bound: Characters <= unicodeScalars. Collapsing with a 320-scalar cap
    // either proves prefix(320) == whole text (cap not exceeded at end) or aborts
    // with bounded waste; the identity (" "+X).collapsed == X.collapsed holds
    // because the leader cannot fuse (guarded above).
    var contiguous = text
    if let whole = contiguous.withUTF8({ BytePath.collapse($0, scalarCap: 320) }) {
        return whole
    }
    // Long text: walk 320 graphemes, collapse the substring in place.
    let end = text.index(text.startIndex, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
    return text[text.startIndex..<end].collapsedInPlace
}

// ===== differential corpus =====
var rng = SystemRandomNumberGenerator()
let atoms = ["a", " ", "  ", "\t", "\r\n", "中", "文", "\u{301}", "\u{200D}", "\u{0600}", "\u{3000}", "\u{A0}", "👨", "🏻", "\u{0E33}", "\u{111C3}", "x", "\n", "English", "　", "\u{903}", "é", "\u{1F3FB}", "👨\u{200D}👩\u{200D}👧"]
var failures = 0, checked = 0
func check(_ text: String, _ label: String) {
    checked += 1
    let o = excerptOld(text), n = excerptNew(text)
    if o != n {
        failures += 1
        if failures <= 8 {
            print("FAIL [\(label)] old.count=\(o.count) new.count=\(n.count) input.len=\(text.count)/\(text.utf8.count)B input=\(text.prefix(50).debugDescription)")
            // show first divergence
            let zo = Array(o), zn = Array(n)
            for idx in 0..<min(zo.count, zn.count) where zo[idx] != zn[idx] {
                print("  first diff at char \(idx): old=\(zo[idx].debugDescription) new=\(zn[idx].debugDescription)")
                break
            }
        }
    }
}
for lead in ["", " ", "\u{301}", "\u{200D}", "\u{0600}", "\u{3000}", "\n", "👨", "\u{0E33}", "\u{111C3}", "\u{1F3FB}", "中", "👨\u{200D}👩"] {
    for body in ["", "a", "abc def", "中文 混排 English words", String(repeating: "字", count: 318), String(repeating: "字", count: 319), String(repeating: "字", count: 320), String(repeating: "字", count: 321), String(repeating: "字", count: 322), String(repeating: "ab ", count: 120), String(repeating: "ab ", count: 200), "a\u{301}b\u{301}c", "\t\tx  y\r\n", String(repeating: "👨\u{200D}👩", count: 100)] {
        for tail in ["", " ", "  ", "\u{301}", "\n", "中"] {
            check(lead + body + tail, "edge")
        }
    }
}
for trial in 0..<40000 {
    var s = ""
    let n = Int.random(in: 0...45, using: &rng)
    for _ in 0..<n { s += atoms[Int.random(in: 0..<atoms.count, using: &rng)] }
    switch trial % 4 {
    case 0: s += String(repeating: "長", count: Int.random(in: 300...345, using: &rng))
    case 1: s += String(repeating: "ab ", count: Int.random(in: 100...115, using: &rng))
    case 2: s += String(repeating: "👨\u{200D}👩", count: Int.random(in: 60...120, using: &rng))
    default: break
    }
    check(s, "fuzz\(trial)")
}
print("checked=\(checked) failures=\(failures)")
