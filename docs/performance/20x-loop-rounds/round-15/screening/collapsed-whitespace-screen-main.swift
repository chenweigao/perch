// Round-15 screening: collapsedWhitespace byte-path rewrite (de-witnessed range
// checks, bulk ASCII runs, property quick-rejects). v0 = verbatim current
// product code; v1 = candidate rewrite; strict = Character-accurate oracle.
// Correctness: three-way differential fuzz. Timing: 9 alternating blocks over
// rotating excerpt-shaped inputs, hash-consumed outputs (anti-hoisting).
import Foundation

// MARK: - v0: verbatim copy of Sources/WorkbenchCore/ConversationProjection.swift

extension String {
    func v0() -> String {
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
                    if V0.isPrependScalar(lastScalar) { return strict() }
                    while i < bytes.count, bytes[i] == 0x20 || (0x09...0x0D).contains(bytes[i]) { i += 1 }
                    if i < bytes.count, bytes[i] >= 0x80, V0.beginsBindingMark(in: bytes, at: i) { return strict() }
                    if !out.isEmpty { pendingSpace = true }
                } else if byte < 0x80 {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    out.append(byte)
                    lastScalar = 0
                    i += 1
                } else {
                    guard let (scalar, length) = V0.utf8Scalar(in: bytes, at: i),
                          !V0.isNonASCIIWhitespace(scalar) else { return strict() }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    for offset in 0..<length { out.append(bytes[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

enum V0 {
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
    static func beginsBindingMark(in bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        guard let (value, _) = utf8Scalar(in: bytes, at: i), let scalar = Unicode.Scalar(value) else { return true }
        if isNeverBindingScalar(value) { return false }
        if value == 0x200D || scalar.properties.isGraphemeExtend { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
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
}

// MARK: - v1: candidate rewrite

extension String {
    var v1: String {
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
                if V1.isWhitespaceByte(byte) {
                    if V1.isPrependScalar(lastScalar) { return strict() }
                    while i < bytes.count, V1.isWhitespaceByte(bytes[i]) { i += 1 }
                    if i < bytes.count, bytes[i] >= 0x80, V0.beginsBindingMark(in: bytes, at: i) { return strict() }
                    if !out.isEmpty { pendingSpace = true }
                } else if byte < 0x80 {
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    // Bulk-copy the ASCII run: one capacity-checked append
                    // instead of one per byte.
                    var j = i + 1
                    while j < bytes.count {
                        let b = bytes[j]
                        if b >= 0x80 || V1.isWhitespaceByte(b) { break }
                        j += 1
                    }
                    out.append(contentsOf: bytes[i..<j])
                    lastScalar = 0
                    i = j
                } else {
                    guard let (scalar, length) = V0.utf8Scalar(in: bytes, at: i),
                          !V1.isNonASCIIWhitespace(scalar) else { return strict() }
                    if pendingSpace { out.append(0x20); pendingSpace = false }
                    for offset in 0..<length { out.append(bytes[i + offset]) }
                    lastScalar = scalar
                    i += length
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

enum V1 {
    @inline(__always)
    static func isWhitespaceByte(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }
    /// The whole pinned Prepend set lives below 0x16D44; the block table is
    /// DERIVED from the exact predicate (single source of truth), so extending
    /// the pinned set automatically extends the quick-reject.
    static let prependBlocks: [Bool] = {
        var blocks = [Bool](repeating: false, count: 0x170)
        for block in 0..<0x170 {
            let base = UInt32(block * 256)
            for offset in 0..<256 where V0.isPrependScalar(base + UInt32(offset)) {
                blocks[block] = true
                break
            }
        }
        return blocks
    }()
    static func isPrependScalar(_ scalar: UInt32) -> Bool {
        let block = Int(scalar >> 8)
        guard block < prependBlocks.count, prependBlocks[block] else { return false }
        return V0.isPrependScalar(scalar)
    }
    static func isNonASCIIWhitespace(_ scalar: UInt32) -> Bool {
        // The pinned White_Space set outside ASCII ends at U+3000.
        guard scalar <= 0x3000 else { return false }
        return V0.isNonASCIIWhitespace(scalar)
    }
}

// MARK: - correctness: three-way differential

func strictCollapse(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

var failures = 0
func check(_ s: String, _ name: String) {
    let a = s.v0()
    let b = s.v1
    let c = strictCollapse(s)
    if a != b || a != c {
        failures += 1
        print("MISMATCH \(name): v0==v1 \(a == b), v0==strict \(a == c)")
        if failures > 10 { fatalError("too many mismatches") }
    }
}

// Fixed edge corpus
var corpus: [String] = [
    "", " ", "  \t\n\r  ", "a", " a ", "a\u{00A0}b", "a\u{3000}b", "a\u{2028}b",
    "a\u{0600} b", "a\u{0600}b", "\u{0600} b", "a\u{06DD} b", "a\u{111C2} b", "a\u{111C3} b",
    "a\u{113D1} b", "a\u{16D43} b", "a\u{16D40} b",
    "a b\u{0301}", "a\u{0301} b", "a b\u{200D}c", "a b\u{093C}c",
    "汉字 汉字", "汉字  混合 English words 与数字 12345", "  leading and trailing  ",
    "tab\tseparated\nnewline\r\nCRLF mix", "emoji 🎉 party 🎊 text", "한글 글자 검사",
    "かな カナ ｶﾅ", "a\u{070F}b c", "multi   space    runs     everywhere",
    "code `let x = 1` 与 **结论** 混排", "\u{2000}\u{200A} exotic spaces \u{205F}\u{202F}",
    "combining after space a \u{0301}b", "Prepend\u{0890} x", "\u{0891} y",
]
// Randomized fuzz: random runs of whitespace/ASCII/CJK/combining/Prepend pieces
var seed: UInt64 = 0x7231_3563_7265_656E
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 11 }
func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
let pieces = [" ", "  ", "\t", "\n", "\r", "\r\n", "a", "z", "0", "汉", "字", "한", "글", "か", "ナ",
              "\u{0301}", "\u{200D}", "\u{0600}", "\u{111C2}", "\u{00A0}", "\u{3000}", "\u{2028}",
              "🎉", "\u{093C}", "English", "混排", "`x`", "**b**", "\u{070F}", "\u{16D43}"]
for trial in 0..<40000 {
    var s = ""
    for _ in 0..<(1 + pick(12)) { s += pieces[pick(pieces.count)] }
    check(s, "fuzz\(trial)")
}
for fixed in corpus { check(fixed, "corpus") }
print(failures == 0 ? "EQUIVALENCE: PASS (\(corpus.count) fixed + 40000 fuzz, three-way)" : "EQUIVALENCE: FAIL \(failures)")
guard failures == 0 else { exit(1) }

// MARK: - timing: rotating excerpt-shaped inputs

let proseBlock = String(repeating: "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，混排 English words so that line breaking has to handle both scripts. ", count: 3)
var inputs: [String] = []
for i in 0..<64 {
    var s = ""
    for word in 0..<(60 + i) {
        switch word % 5 {
        case 0: s += "第 \(word) 轮：请检查实现与调用方的约束，再决定下一步。 "
        case 1: s += proseBlock.prefix(80) + " "
        case 2: s += "Conclusion \(word): the identifier `value\(word)` was handled, with English notes. "
        case 3: s += "混排 English 与数字 \(word)\t制表符\n换行 "
        default: s += "```swift\nlet value\(word) = compute(\(word)) // 源代码行\n``` "
        }
    }
    inputs.append(String(s.prefix(320 * 3)))
}
for input in inputs { precondition(input.utf8.count > 300) }
print("inputs: \(inputs.count), bytes \(inputs[0].utf8.count)...\(inputs[inputs.count-1].utf8.count)")

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
var v0Times: [Double] = [], v1Times: [Double] = []
let iters = 20000
for block in 0..<9 {
    var hash = UInt64(block)
    var t = Date().timeIntervalSince1970
    for n in 0..<iters { hash = hash &* 31 &+ UInt64(inputs[n % 64].v0().utf8.count) }
    v0Times.append((Date().timeIntervalSince1970 - t) * 1000 / Double(iters))
    t = Date().timeIntervalSince1970
    for n in 0..<iters { hash = hash &* 31 &+ UInt64(inputs[n % 64].v1.utf8.count) }
    v1Times.append((Date().timeIntervalSince1970 - t) * 1000 / Double(iters))
    if hash == 0 { print("never") }
    print("block \(block): v0=\(String(format: "%.6f", v0Times.last!))ms v1=\(String(format: "%.6f", v1Times.last!))ms")
}
let m0 = median(v0Times), m1 = median(v1Times)
print(String(format: "median ms/call over %d blocks (each labeled ms but divided per call): v0=%.6f v1=%.6f change=%+.2f%%", 9, m0, m1, (m1 / m0 - 1) * 100))
print("per-block changes: " + zip(v0Times, v1Times).map { String(format: "%+.1f%%", ($0.1 / $0.0 - 1) * 100) }.joined(separator: " "))
