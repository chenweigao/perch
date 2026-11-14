import Foundation

// ===== machinery (round-11 product byte path) =====
struct BP {
    static func isPrependScalar(_ s: UInt32) -> Bool {
        switch s {
        case 0x0600...0x0605, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2, 0x0D4E, 0x110BD, 0x110CD,
             0x111C2...0x111C3, 0x113D1, 0x1193F, 0x11941, 0x11A3A, 0x11A84...0x11A89, 0x11D46,
             0x11F02, 0x16D40...0x16D43: return true
        default: return false
        }
    }
    static func isNonASCIIWhitespace(_ s: UInt32) -> Bool {
        switch s {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }
    static func utf8Scalar(in b: UnsafeBufferPointer<UInt8>, at i: Int) -> (UInt32, Int)? {
        func cont(_ j: Int) -> Bool { j < b.count && b[j] & 0xC0 == 0x80 }
        switch b[i] {
        case 0xC2...0xDF: guard cont(i+1) else { return nil }
            return (UInt32(b[i] & 0x1F) << 6 | UInt32(b[i+1] & 0x3F), 2)
        case 0xE0...0xEF: guard cont(i+1), cont(i+2) else { return nil }
            return (UInt32(b[i] & 0x0F) << 12 | UInt32(b[i+1] & 0x3F) << 6 | UInt32(b[i+2] & 0x3F), 3)
        case 0xF0...0xF4: guard cont(i+1), cont(i+2), cont(i+3) else { return nil }
            return (UInt32(b[i] & 0x07) << 18 | UInt32(b[i+1] & 0x3F) << 12 | UInt32(b[i+2] & 0x3F) << 6 | UInt32(b[i+3] & 0x3F), 4)
        default: return nil
        }
    }
    static func isNeverBinding(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x11FF, 0x3001...0x3029, 0x3030...0x303E, 0x3041...0x3096, 0x309D...0x309F,
             0x30A1...0x30FF, 0x3105...0x312F, 0x3131...0x318E, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFF01...0xFF60, 0xFF61...0xFF9D, 0xFFA0...0xFFDC: return true
        default: return false
        }
    }
    static func beginsBindingMark(in b: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard let (v, _) = utf8Scalar(in: b, at: i), let s = Unicode.Scalar(v) else { return true }
        if isNeverBinding(v) { return false }
        if v == 0x200D || s.properties.isGraphemeExtend { return true }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
    static func collapse(_ bytes: UnsafeBufferPointer<UInt8>, cap: Int?) -> String? {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var pendingSpace = false, lastScalar: UInt32 = 0, scalars = 0, i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x20 || (0x09...0x0D).contains(byte) {
                if isPrependScalar(lastScalar) { return nil }
                while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) {
                    i += 1; scalars += 1
                    if let c = cap, scalars > c { return nil }
                }
                if i < bytes.count, bytes[i] >= 0x80, beginsBindingMark(in: bytes, at: i) { return nil }
                if !out.isEmpty { pendingSpace = true }
            } else if byte < 0x80 {
                if pendingSpace { out.append(0x20); pendingSpace = false }
                out.append(byte); lastScalar = 0; i += 1; scalars += 1
                if let c = cap, scalars > c { return nil }
            } else {
                guard let (sv, len) = utf8Scalar(in: bytes, at: i), !isNonASCIIWhitespace(sv) else { return nil }
                if pendingSpace { out.append(0x20); pendingSpace = false }
                for o in 0..<len { out.append(bytes[i + o]) }
                lastScalar = sv; i += len; scalars += 1
                if let c = cap, scalars > c { return nil }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
    /// decode-only scalar count; aborts with nil once count exceeds cap
    static func scalarCountAtMost(_ bytes: UnsafeBufferPointer<UInt8>, cap: Int) -> Bool {
        var scalars = 0, i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if byte < 0x80 { i += 1 }
            else if let (_, len) = utf8Scalar(in: bytes, at: i) { i += len }
            else { return true } // invalid → let caller's normal path handle
            scalars += 1
            if scalars > cap { return false }
        }
        return true
    }
}
extension String {
    var collapsedWhitespace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var c = self
        let fast: String? = c.withUTF8 { BP.collapse($0, cap: nil) }
        return fast ?? strict()
    }
}
extension Substring {
    var collapsedInPlace: String {
        let strict = { self.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard let fast = utf8.withContiguousStorageIfAvailable({ BP.collapse($0, cap: nil) }) else { return strict() }
        return fast ?? strict()
    }
}

// ===== variants =====
func leaderGuard(_ text: String) -> Bool { // true = must use old formula
    if let first = text.unicodeScalars.first {
        let v = first.value
        if v >= 0x80, !BP.isNeverBinding(v) {
            let head = text.prefix(2)
            if (" " + head).count < head.count + 1 { return true }
        }
    }
    return false
}
func v0(_ text: String) -> String { (" " + String(text.prefix(320))).collapsedWhitespace }
func v1(_ text: String) -> String { // capped fused collapse
    if leaderGuard(text) { return v0(text) }
    var c = text
    if let whole = c.withUTF8({ BP.collapse($0, cap: 320) }) { return whole }
    let end = text.index(text.startIndex, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
    return text[text.startIndex..<end].collapsedInPlace
}
func v2(_ text: String) -> String { // count-first
    if leaderGuard(text) { return v0(text) }
    var c = text
    if let r = c.withUTF8({ bytes -> String? in
        if bytes.count <= 320 || BP.scalarCountAtMost(bytes, cap: 320) {
            return BP.collapse(bytes, cap: nil)
        }
        return nil
    }) { return r ?? v0(text) }
    let end = text.index(text.startIndex, offsetBy: 320, limitedBy: text.endIndex) ?? text.endIndex
    return text[text.startIndex..<end].collapsedInPlace
}

// ===== fixture-shaped texts (64 rotating variants to defeat hoisting) =====
let prose = Array(repeating: "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，混排 English words so that line breaking has to handle both scripts.", count: 3).joined(separator: "\n\n")
func variants(_ make: (Int) -> String) -> [String] { (0..<64).map(make) }
let userTexts = variants { "第 \($0) 轮：" + prose }
let assistantTexts = variants { "回答如下 \($0)。\n\n" + prose + "\n\n```swift\nlet value = \($0)\n```" }
let shortTexts = variants { "好的 \($0)，我来处理这个任务。" }
let longAsciiTexts = variants { String(repeating: "word\($0) ", count: 400) }
let suites = [("user(339sc,CJK)", userTexts), ("assistant(368sc,CJK)", assistantTexts), ("short", shortTexts), ("longAscii", longAsciiTexts)]
for (name, texts) in suites {
    let t = texts[0]
    print("\(name): chars=\(t.count) scalars=\(t.unicodeScalars.count) bytes=\(t.utf8.count)")
}

// ===== alternating block benchmark (anti-hoisting: rotate 64 inputs, consume hashes) =====
@inline(never)
func bench(_ texts: [String], _ f: (String) -> String, iterations: Int) -> Double {
    var sink = 0
    let t0 = DispatchTime.now()
    for i in 0..<iterations {
        let r = f(texts[i & 63])
        sink &+= r.hashValue & 0xFF
    }
    let t1 = DispatchTime.now()
    if sink == Int.min { print("") }
    return Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 / Double(iterations)
}
let iters = 20000
print("\nµs/call median of 9 blocks, \(iters) iters/block, 64 rotating inputs")
for (name, texts) in suites {
    var r0: [Double] = [], r1: [Double] = [], r2: [Double] = []
    for _ in 0..<9 {
        r0.append(bench(texts, v0, iterations: iters))
        r1.append(bench(texts, v1, iterations: iters))
        r2.append(bench(texts, v2, iterations: iters))
    }
    r0.sort(); r1.sort(); r2.sort()
    print(String(format: "%@: v0=%.4f v1=%.4f (%+.1f%%) v2=%.4f (%+.1f%%)", name, r0[4], r1[4], (r1[4]/r0[4]-1)*100, r2[4], (r2[4]/r0[4]-1)*100))
}
for (_, texts) in suites { for t in texts { precondition(v0(t) == v1(t) && v0(t) == v2(t), "variant mismatch") } }
print("variants agree on all bench texts")
