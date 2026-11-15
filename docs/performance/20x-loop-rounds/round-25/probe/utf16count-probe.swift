// Round-25 sizing probe: stdlib String.utf16.count vs a SWAR byte-level
// UTF-16 unit count, on the string shapes the ConversationActivity written
// loop sees (CJK-mixed assistant text, ASCII, long CJK, emoji).
// SWAR identity for valid UTF-8: utf16Units = #(lead bytes: (b & 0xC0) != 0x80)
//                                      + #(four-byte leads: b >= 0xF0)
// Timing-only mechanism probe; adoption would be decided by in-context A/B.
import Foundation

func swarUTF16Count(_ text: String) -> Int {
    var contiguous = text
    return contiguous.withUTF8 { bytes -> Int in
        let n = bytes.count
        guard let base = bytes.baseAddress else { return 0 }
        var leads = 0, fourByte = 0, i = 0
        let p = UnsafeRawPointer(base)
        while i + 8 <= n {
            let word = p.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            // lead bytes: (b & 0xC0) != 0x80  <=>  ((b + 0x40) & 0x80) != 0 ... use per-byte high-bit math
            // count continuation bytes: (b & 0xC0) == 0x80 -> mark via ((b & 0xC0) ^ 0x80) == 0
            let t = word ^ 0x8080808080808080          // continuation bytes become 0x00 in high pattern? do classic:
            // continuation: b & 0xC0 == 0x80  <=>  (b | 0x3F) == 0xBF... use haszero of ((b & 0xC0) ^ 0x80)
            let masked = (word & 0xC0C0C0C0C0C0C0C0) ^ 0x8080808080808080  // zero byte where continuation
            let x = masked
            let m7 = 0x7F7F7F7F7F7F7F7F as UInt64
            let contMarks = ~(((x & m7) &+ m7) | x | m7)   // high bit set per continuation byte
            let contCount = contMarks.nonzeroBitCount       // 1 bit per continuation byte (bit7 of each)
            // four-byte leads: b >= 0xF0 <=> (b + 0x10) overflows byte high nibble... use saturating compare:
            let y = word &+ 0x1010101010101010              // b >= 0xF0 <=> b+0x10 has bit 0x00 with carry out of byte
            // detect bytes where b >= 0xF0: (b | 0x0F) == 0xFF -> high nibble F. high nibble == 0xF:
            let hi = word & 0xF0F0F0F0F0F0F0F0
            let hiF = hi ^ 0xF0F0F0F0F0F0F0F0               // zero byte where high nibble == F
            let fMarks = ~(((hiF & m7) &+ m7) | hiF | m7)
            let fCount = fMarks.nonzeroBitCount
            _ = t; _ = y
            leads += 8 - contCount
            fourByte += fCount
            i += 8
        }
        while i < n {
            let b = bytes[i]
            if b & 0xC0 != 0x80 { leads += 1 }
            if b >= 0xF0 { fourByte += 1 }
            i += 1
        }
        return leads + fourByte
    }
}

// correctness sweep
var state: UInt64 = 0x2026_1116_0025
func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 }
let pieces = ["a", "检", "中文", "👩", "🏽", "é", "e\u{301}", " ", "\n", "🇨🇳", "\u{200D}", "x", "𝄞", "한"]
var mismatches = 0
for trial in 0..<20000 {
    var s = ""
    for _ in 0..<(next() % 20) { s += pieces[Int(next() % UInt64(pieces.count))] }
    if s.utf16.count != swarUTF16Count(s) { mismatches += 1; if mismatches < 3 { print("MISMATCH \(s.debugDescription): stdlib \(s.utf16.count) swar \(swarUTF16Count(s))") } }
}
print("correctness: 20000 random strings, mismatches = \(mismatches)")

func bench(_ label: String, _ texts: [String], _ body: (String) -> Int) {
    var sink = 0
    for _ in 0..<3 { for t in texts { sink += body(t) } }
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<7 {
        let t0 = Date()
        var acc = 0
        for _ in 0..<20 { for t in texts { acc += body(t) } }
        let dt = Date().timeIntervalSince(t0)
        if dt < best { best = dt }
        sink += acc
    }
    let totalBytes = texts.reduce(0) { $0 + $1.utf8.count } * 20
    let perGB = best / (Double(totalBytes) / 1e9)
    print("\(label): best \(String(format: "%.3f", best*1000)) ms per pass-set, ~\(String(format: "%.2f", perGB*1000)) ms/GB, sink=\(sink % 7)")
}

// shapes mirroring the fixtures/product
let cjkShort = String(repeating: "检查第 123 步。", count: 1)          // ~22B
let cjkTexts = (0..<2000).map { i in "检查第 \(i) 步。请修改实现并验证。" }  // 2000 parts like single_turn fixture
let asciiTexts = (0..<2000).map { i in "check step \(i): run swift test --filter Case\(i) now" }
let longCjk = [String(repeating: "说明这一轮的结论与 English identifiers，保持中文混排。", count: 60)]  // ~4KB+
let emojiTexts = (0..<500).map { _ in "结果 👩🏽‍💻 完成 🇨🇳 步骤 \(0)" }

for (name, texts) in [("cjk-2000-parts  ", cjkTexts), ("ascii-2000-parts", asciiTexts), ("long-cjk-4KB    ", longCjk), ("emoji-500-parts ", emojiTexts)] {
    bench("\(name) stdlib utf16.count", texts) { $0.utf16.count }
    bench("\(name) swar byte count  ", texts) { swarUTF16Count($0) }
    print("")
}
print("single short cjk string overhead (per-call):")
let one = [cjkShort]
bench("  stdlib", Array(repeating: one[0], count: 10000)) { $0.utf16.count }
bench("  swar  ", Array(repeating: one[0], count: 10000)) { swarUTF16Count($0) }
