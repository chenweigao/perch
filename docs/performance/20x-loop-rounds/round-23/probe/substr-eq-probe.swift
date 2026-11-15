// Mechanism probe: does Substring == have a byte-equality fast path for
// non-ASCII content? Compare timing of (a) byte-identical pairs,
// (b) canonically-equal byte-differing pairs (NFC vs NFD), (c) differing pairs.
import Foundation

let rowsAscii = (0..<64).map { "let value\($0) = compute(\($0)) // comment" }
let rowsCjk = (0..<64).map { "let value\($0) = compute(\($0)) // 中文 café" }
let oldC = rowsCjk.joined(separator: "\n")
let newC = oldC.decomposedStringWithCanonicalMapping  // canonically equal, bytes differ (é)
let oldA = rowsAscii.joined(separator: "\n")

func sub(_ s: String, line: Int) -> Substring {
    s.split(separator: "\n", omittingEmptySubsequences: false)[line]
}

func timeIt(_ label: String, _ body: () -> Bool) {
    var sink = false
    // warmup
    for _ in 0..<20000 { sink = sink != body() }
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<7 {
        let t0 = Date()
        var acc = true
        for _ in 0..<200000 { acc = acc && body() }
        let dt = Date().timeIntervalSince(t0) * 1000
        if dt < best { best = dt }
        if !acc || acc { sink = true }
    }
    print("\(label): best \(String(format: "%.3f", best)) ms / 200k comparisons\(sink ? "" : "")")
}

let aC1 = sub(oldC, line: 32), aC2 = sub(oldC, line: 32)          // byte-identical non-ASCII (same base)
let bC1 = sub(oldC, line: 32), bC2 = sub(newC, line: 32)          // canonical-equal, bytes differ
let cC1 = sub(oldC, line: 32), cC2 = sub(newC, line: 33)          // genuinely different
let aA1 = sub(oldA, line: 32), aA2 = sub(oldA, line: 32)          // byte-identical ASCII
// cross-base byte-identical: decode-independent second copy
let oldC2 = String(decoding: Array(oldC.utf8), as: UTF8.self)
let dC1 = sub(oldC, line: 32), dC2 = sub(oldC2, line: 32)         // byte-identical, different bases

timeIt("ascii same-base identical     ", { aA1 == aA2 })
timeIt("cjk   same-base identical     ", { aC1 == aC2 })
timeIt("cjk   cross-base identical    ", { dC1 == dC2 })
timeIt("cjk   canonical-equal diffbyte", { bC1 == bC2 })
timeIt("cjk   different lines         ", { cC1 == cC2 })
