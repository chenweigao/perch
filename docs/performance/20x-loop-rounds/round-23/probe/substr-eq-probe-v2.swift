// Mechanism probe v2 (review F7 correction). v1 flaws: (a) the "different
// lines" case used `acc && body()`, which short-circuits after the first
// false — 7 total calls, not 1.4M, invalidating its ~0.4ns figure; (b) the
// candidate's raw byte-loop cost (~1-2ns) was claimed without measurement.
// v2 fixes both and defeats loop-invariant hoisting (a first XOR-accumulation
// rewrite measured 0.000ms — the optimizer lifted the constant comparisons):
// every case indexes a pre-built 64-pair array by the iteration counter, so
// each timed call compares genuinely different content.
// Timing-only probe on Linux; adoption is decided solely by in-context A/B.
import Foundation

let rowsCjk = (0..<64).map { "let value\($0) = compute(\($0)) // 中文 café" }
let oldC = rowsCjk.joined(separator: "\n")
let newC = oldC.decomposedStringWithCanonicalMapping          // canonically equal, bytes differ
let oldC2 = String(decoding: Array(oldC.utf8), as: UTF8.self) // cross-base identical copy
let oldD = (0..<64).map { "let value\($0) = computeX(\($0)) // 中文 café" }.joined(separator: "\n")
let rowsAscii = (0..<64).map { "let value\($0) = compute(\($0)) // comment" }
let oldA = rowsAscii.joined(separator: "\n")

func splitLines(_ s: String) -> [Substring] { s.split(separator: "\n", omittingEmptySubsequences: false) }
let linesC = splitLines(oldC), linesC2 = splitLines(oldC2), linesN = splitLines(newC),
    linesD = splitLines(oldD), linesA = splitLines(oldA)
precondition(linesC.count == 64 && linesN.count == 64 && linesD.count == 64)

func lineBounds(_ s: String) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = 0, i = 0
    let bytes = Array(s.utf8)
    while i < bytes.count {
        if bytes[i] == 0x0A { out.append(start..<i); start = i + 1 }
        i += 1
    }
    out.append(start..<bytes.count)
    return out
}
let boundsC = lineBounds(oldC), boundsC2 = lineBounds(oldC2)

func timeIt(_ label: String, _ body: (Int) -> Bool) {
    var acc = false
    for i in 0..<20000 { acc = acc != body(i & 63) }        // warmup
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<7 {
        let t0 = Date()
        for i in 0..<200000 { acc = acc != body(i & 63) }   // varying inputs; every call evaluated
        let dt = Date().timeIntervalSince(t0) * 1000
        if dt < best { best = dt }
    }
    if acc { print("(acc consumed)") }
    print("\(label): best \(String(format: "%.3f", best)) ms / 200k comparisons")
}

timeIt("ascii same-base identical      ", { linesA[$0] == linesA[$0] })
timeIt("cjk   same-base identical      ", { linesC[$0] == linesC[$0] })
timeIt("cjk   cross-base identical     ", { linesC[$0] == linesC2[$0] })
timeIt("cjk   canonical-equal diffbyte ", { linesC[$0] == linesN[$0] })
timeIt("cjk   different lines          ", { linesC[$0] == linesD[$0] })

// Raw byte-loop comparison with precomputed bounds — the shape of the
// candidate's lineRangesEqual fast path (cross-base identical content).
var s1 = oldC
var s2 = oldC2
timeIt("raw byte loop cross-base ident ", { k in
    let r1 = boundsC[k], r2 = boundsC2[k]
    return s1.withUTF8 { x in s2.withUTF8 { y in
        guard r1.count == r2.count else { return false }
        var i = 0
        while i < r1.count {
            if x[r1.lowerBound + i] != y[r2.lowerBound + i] { return false }
            i += 1
        }
        return true
    }}
})
