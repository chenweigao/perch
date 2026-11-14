// Round-15 screening #2: SessionEditStats.lineCount scan rewrites.
// v0 = verbatim product closure; v1 = split predicates (LF count - CRLF pairs);
// v2 = SWAR 8-byte word scan with popcount. Equivalence: v1/v2 must equal v0
// on fixed corpus + seeded fuzz. Timing: 9 alternating blocks, rotating
// Write-content/edit-block shaped inputs, hash-consumed outputs.
import Foundation

// MARK: v0 — verbatim from SessionEditStats.lineCount (contiguous branch + fallback)
func lineCountV0(_ text: String) -> Int {
    if let count = text.utf8.withContiguousStorageIfAvailable({ bytes -> Int in
        var count = 1
        for offset in bytes.indices where bytes[offset] == 0x0A && (offset == 0 || bytes[offset - 1] != 0x0D) {
            count += 1
        }
        return count
    }) { return count }
    var count = 1
    var previous: UInt8 = 0
    for byte in text.utf8 {
        if byte == 0x0A && previous != 0x0D { count += 1 }
        previous = byte
    }
    return count
}

// MARK: v1 — split predicates: total LFs minus CRLF pairs
func lineCountV1(_ text: String) -> Int {
    var contiguous = text
    return contiguous.withUTF8 { bytes -> Int in
        let n = bytes.count
        var lf = 0
        var i = 0
        while i < n {
            if bytes[i] == 0x0A { lf += 1 }
            i += 1
        }
        var crlf = 0
        i = 1
        while i < n {
            if bytes[i] == 0x0A, bytes[i - 1] == 0x0D { crlf += 1 }
            i += 1
        }
        return 1 + lf - crlf
    }
}

// MARK: v2 — SWAR: 8 bytes per iteration, has-zero trick + popcount
@inline(__always)
func hasZero(_ v: UInt64, _ c: UInt64) -> UInt64 {
    // bytes equal to c leave 0x00; hasvalue detection: (x ^ c) has a zero byte
    let x = v ^ c
    return (x &- 0x0101010101010101) & ~x & 0x8080808080808080
}
func lineCountV2(_ text: String) -> Int {
    var contiguous = text
    return contiguous.withUTF8 { bytes -> Int in
        let n = bytes.count
        guard let base = bytes.baseAddress else { return 1 }
        let lfPattern: UInt64 = 0x0A0A0A0A0A0A0A0A
        let crPattern: UInt64 = 0x0D0D0D0D0D0D0D0D
        var lf = 0
        var crlf = 0
        var i = 0
        // True when the byte just before the current word is CR (the previous
        // word's CR marker sat at its bit 63).
        var prevByteIsCR = false
        while i + 8 <= n {
            let word = UnsafeRawPointer(base).loadUnaligned(fromByteOffset: i, as: UInt64.self)
            let a = hasZero(word, lfPattern)          // 0x80 at each LF byte
            let d = hasZero(word, crPattern)          // 0x80 at each CR byte
            lf += a.nonzeroBitCount
            // In-word CRLF pairs: LF at byte k, CR at byte k-1 — shifting the
            // CR mask left 8 bits (little-endian) aligns it to the LF's bit.
            crlf += (a & (d << 8)).nonzeroBitCount
            // Cross-word pair: LF at byte 0 of this word after a CR ending the
            // previous word (the LF marker bit for byte 0 is 0x80).
            if prevByteIsCR && (a & 0x80) != 0 { crlf += 1 }
            prevByteIsCR = (d & 0x8000000000000000) != 0
            i += 8
        }
        // Tail (< 8 bytes), scalar.
        var k = i
        while k < n {
            if bytes[k] == 0x0A {
                lf += 1
                if k > 0 ? bytes[k - 1] == 0x0D : prevByteIsCR { crlf += 1 }
            }
            k += 1
        }
        return 1 + lf - crlf
    }
}

// MARK: equivalence
var failures = 0
func check(_ s: String, _ name: String) {
    let a = lineCountV0(s), b = lineCountV1(s), c = lineCountV2(s)
    if a != b || a != c {
        failures += 1
        print("MISMATCH \(name): v0=\(a) v1=\(b) v2=\(c) for \(s.utf8.count) bytes")
        if failures > 10 { fatalError("too many mismatches") }
    }
}
var corpus: [String] = [
    "", "\n", "\r", "\r\n", "\n\r", "a", "a\n", "a\r\n", "\r\na", "a\r\nb\nc",
    "\r\r\n", "\r\n\n", "\n\n\r\n", "a\r\n\r\nb", "line0\nline1\nline2",
    "trailing\n", "trailing\r\n", "漢字\n漢字\r\nmix", "no newlines at all here",
    String(repeating: "\r\n", count: 100), String(repeating: "x\n", count: 219) + "tail",
    String(repeating: "\r\nx", count: 7) + "\r\n",
]
var seed: UInt64 = 0x6C69_6E65_636F_756E
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 11 }
func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
let pieces = ["a", "b", "\n", "\r", "\r\n", "\n\r", "汉", " ", "line \(0)\t", "\r\r", "\n\n", "x"]
for fixed in corpus { check(fixed, "corpus") }
for trial in 0..<60000 {
    var s = ""
    for _ in 0..<(1 + pick(30)) { s += pieces[pick(pieces.count)] }
    check(s, "fuzz\(trial)")
}
// long aligned/unaligned: ensure SWAR word boundaries covered
for len in [0, 1, 7, 8, 9, 15, 16, 17, 63, 64, 65] {
    for fill in ["\n", "\r", "a"] {
        check(String(repeating: fill, count: len), "len\(len)-\(fill == "\n" ? "lf" : fill == "\r" ? "cr" : "a")")
        check(String(repeating: "ab\(fill)", count: len), "mix\(len)")
        check("x" + String(repeating: fill, count: len) + "\r", "sandwich\(len)")
    }
}
print(failures == 0 ? "EQUIVALENCE: PASS (\(corpus.count) fixed + 60000 fuzz + boundary grid, v0==v1==v2)" : "EQUIVALENCE: FAIL \(failures)")
guard failures == 0 else { exit(1) }

// MARK: timing — Write-content (9KB) and edit-block (1KB) shapes
var inputs: [String] = []
for i in 0..<64 {
    let write = (0..<(200 + i)).map { "line \($0): 写入的文件内容 with mixed text \(i)" }.joined(separator: "\n")
    inputs.append(write)
}
var smallInputs: [String] = []
for i in 0..<64 {
    smallInputs.append((0..<(24 + i % 8)).map { "    let value\($0) = computeFaster(\($0)) // 新实现 \(i)" }.joined(separator: "\n"))
}
print("inputs: large ~\(inputs[0].utf8.count)B, small ~\(smallInputs[0].utf8.count)B")

func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
func bench(_ name: String, _ data: [String], _ f0: (String) -> Int, _ f1: (String) -> Int, _ f2: (String) -> Int, iters: Int) {
    var t0: [Double] = [], t1: [Double] = [], t2: [Double] = []
    for block in 0..<9 {
        var hash = UInt64(block)
        var t = Date().timeIntervalSince1970
        for n in 0..<iters { hash = hash &* 31 &+ UInt64(f0(data[n % 64])) }
        t0.append((Date().timeIntervalSince1970 - t) * 1000 / Double(iters))
        t = Date().timeIntervalSince1970
        for n in 0..<iters { hash = hash &* 31 &+ UInt64(f1(data[n % 64])) }
        t1.append((Date().timeIntervalSince1970 - t) * 1000 / Double(iters))
        t = Date().timeIntervalSince1970
        for n in 0..<iters { hash = hash &* 31 &+ UInt64(f2(data[n % 64])) }
        t2.append((Date().timeIntervalSince1970 - t) * 1000 / Double(iters))
        if hash == 0 { print("never") }
    }
    let m0 = median(t0), m1 = median(t1), m2 = median(t2)
    print(String(format: "%@ ms/call: v0=%.6f v1=%.6f (%+.1f%%) v2=%.6f (%+.1f%%)", name, m0, m1, (m1/m0-1)*100, m2, (m2/m0-1)*100))
    print("  v0 per-block: " + t0.map { String(format: "%.5f", $0) }.joined(separator: " "))
    print("  v2 per-block: " + t2.map { String(format: "%.5f", $0) }.joined(separator: " "))
}
bench("large(9KB)", inputs, lineCountV0, lineCountV1, lineCountV2, iters: 20000)
bench("small(1KB)", smallInputs, lineCountV0, lineCountV1, lineCountV2, iters: 100000)
