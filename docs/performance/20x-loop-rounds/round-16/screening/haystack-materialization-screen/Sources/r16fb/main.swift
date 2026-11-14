// Round-16 screening: materialize the find-bar search haystack as a contiguous
// UTF-16 NSString instead of the lazily bridged Swift String wrapper.
// Attribution (cold find-bar query, 21,067 samples): cf-match 54.0% (semantics
// red line), render 23.0%, utf16-bridge 20.1% — whose 8.5% _nativeGetIndex
// leaf is driven by @objc __StringStorage.character(at:) under the CF/DD
// lexer (computeLexemsAtPosition). Hypothesis: CF reading a real contiguous
// UTF-16 buffer removes the per-character bridge traversal; matching semantics
// (same CFStringFindWithOptionsAndLocale inputs/options) stay byte-identical.
//
// v0 = `s as NSString`                    (product current: lazy __StringStorage)
// v1 = NSString(string: s)                (Foundation initializer — wraps or copies?)
// v2 = CFStringCreateWithCharacters copy  (definite contiguous UTF-16 materialization)
// v3 = NSMutableString(string: s)         (definite copy, mutable class)
//
// Equivalence first: identical [NSRange] match lists, identical excerpts,
// identical .length — over an entry-shaped corpus and adversarial Unicode.
// Timing: 9 alternating blocks, rotating inputs, hash-consumed.
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

func variant(_ s: String, _ v: Int) -> NSString {
    switch v {
    case 1: return NSString(string: s)
    case 2:
        #if canImport(CoreFoundation)
        var chars = Array(s.utf16)
        return chars.withUnsafeMutableBufferPointer { buf in
            CFStringCreateWithCharacters(nil, buf.baseAddress!, CFIndex(buf.count)) as NSString
        }
        #else
        return s as NSString
        #endif
    case 3: return NSMutableString(string: s)
    default: return s as NSString
    }
}

// Product match loop (ConversationSearch.search, literal branch).
func matchLoop(_ text: NSString, _ query: String, _ options: NSString.CompareOptions) -> [NSRange] {
    var matches: [NSRange] = []
    var range = NSRange(location: 0, length: text.length)
    while range.length > 0 {
        let found = text.range(of: query, options: options, range: range)
        guard found.location != NSNotFound else { break }
        matches.append(found)
        range = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
    }
    return matches
}

// Product excerpt (start-50, end+80, composed-sequence aligned).
func excerpts(_ text: NSString, _ matches: [NSRange]) -> [String] {
    matches.map { found in
        let start = max(0, found.location - 50), end = min(text.length, NSMaxRange(found) + 80)
        let r = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return text.substring(with: r)
    }
}

// ---- corpus: entry-shaped texts from the streaming bench fixture ----
let thinking = String(repeating: "先确认当前实现与调用方的约束，再决定下一步 inspect the call sites. ", count: 9)
let prompt = String(repeating: "请继续推进这个任务，修复问题并验证结果。", count: 8)
let answer = (0..<12).map { "- 第 \($0) 项结论：`Identifier\($0)` 已经处理，并附带 English notes for the reader." }.joined(separator: "\n")
let readOutput = (0..<60).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
let bashOutput = (0..<24).map { "PASS case \($0) 通过 in 0.0\($0)s" }.joined(separator: "\n")
let grepOutput = (0..<16).map { "Sources/File\($0).swift:\($0 * 7): match 匹配行" }.joined(separator: "\n")
let written = (0..<90).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")
let oldBlock = (0..<14).map { "    let value\($0) = compute(\($0)) // 原有实现" }.joined(separator: "\n")

var corpus: [String] = []
for step in 0..<64 {
    switch step % 8 {
    case 0: corpus.append([thinking, "检查第 \(step) 步的结果。", "Read", "/repo/Sources/File\(step).swift", readOutput].joined(separator: "\n"))
    case 1: corpus.append([thinking, "Bash", "swift test --filter Case\(step)", bashOutput].joined(separator: "\n"))
    case 2: corpus.append([thinking, "Grep", "compute\\(", grepOutput].joined(separator: "\n"))
    case 3: corpus.append([thinking, "Edit", oldBlock, "ok"].joined(separator: "\n"))
    case 4: corpus.append([thinking, "Write", written].joined(separator: "\n"))
    case 5: corpus.append(["第 \(step) 轮：\(prompt)"].joined())
    case 6: corpus.append([thinking, "完成。\n\n\(answer)"].joined(separator: "\n"))
    default: corpus.append([readOutput, bashOutput, grepOutput, written].joined(separator: "\n"))
    }
}
let bigText = corpus.joined(separator: "\n")  // ~120KB upper-bound entry

// ---- adversarial equivalence set ----
let adversarial: [String] = [
    "e\u{0301}clair 已经处理 eclair",           // NFD é + query chars
    "\u{00E9}clair fold É CLAIRE",              // NFC é, case fold
    "处理\u{1F469}\u{200D}\u{1F4BB}已经处理",    // ZWJ emoji between hits
    "ß SS straße 已经处理",                      // sharp s
    "İstanbul i\u{0307} i 已经处理",             // dotted capital I
    "\u{65E5}\u{672C}\u{8A9E} 已经处理 \u{0394}\u{03B4}", // CJK + Greek case pair
    "已经处理\r\n已经处理\n已经处理",              // CRLF separators between hits
    String(repeating: "a\u{0300}", count: 500) + " 已经处理", // 500 combining sequences
    "",                                          // empty
    "已经处理",                                   // exact query only
    "no match here at all",                      // miss
    String(repeating: "已经处理", count: 200),     // dense hits
]
let queries = ["已经处理", "inspect", "e", "É", "处理"]
let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

// ---- equivalence ----
var failures = 0
var checked = 0
for text in corpus + adversarial + [bigText] {
    let base0 = variant(text, 0)
    for q in queries {
        let m0 = matchLoop(base0, q, opts)
        let e0 = excerpts(base0, m0)
        for v in 1...3 {
            let tv = variant(text, v)
            guard tv.length == base0.length else { print("FAIL length v\(v) q=\(q): \(tv.length) vs \(base0.length)"); failures += 1; continue }
            let mv = matchLoop(tv, q, opts)
            let ev = excerpts(tv, mv)
            if mv != m0 || ev != e0 {
                print("FAIL match/excerpt v\(v) q=\(q) text=\(text.prefix(40)): \(mv.count) vs \(m0.count)")
                failures += 1
            }
            checked += 1
        }
    }
}
print("EQUIVALENCE: \(failures == 0 ? "PASS" : "FAIL(\(failures))") (\(checked) variant comparisons, \(queries.count) queries, \(corpus.count + adversarial.count + 1) texts)")
guard failures == 0 else { exit(1) }

// also verify plain-`as` caseSensitive behaves (options parity sanity)
let csOpts: NSString.CompareOptions = []
for text in adversarial {
    let m0 = matchLoop(variant(text, 0), "已经处理", csOpts)
    for v in 1...3 where matchLoop(variant(text, v), "已经处理", csOpts) != m0 {
        print("FAIL case-sensitive parity v\(v)"); failures += 1
    }
}
guard failures == 0 else { exit(1) }

// ---- timing ----
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

func sweep(_ v: Int, _ q: String) -> (ms: Double, hash: Int) {
    var hash = 0
    let t0 = now()
    for text in corpus {
        let tv = variant(text, v)
        for m in matchLoop(tv, q, opts) { hash = hash &* 31 &+ m.location &+ NSMaxRange(m) }
        hash = hash &* 31 &+ tv.length
    }
    return (now() - t0, hash)
}
func big(_ v: Int, _ q: String) -> (ms: Double, hash: Int) {
    var hash = 0
    let t0 = now()
    let tv = variant(bigText, v)
    for m in matchLoop(tv, q, opts) { hash = hash &* 31 &+ m.location }
    hash = hash &* 31 &+ tv.length
    return (now() - t0, hash)
}

let names = ["v0-bridge", "v1-nsinit", "v2-cfchars", "v3-mutable"]
for q in ["已经处理", "inspect"] {
    var corpusBlocks: [[Double]] = Array(repeating: [], count: 4)
    var bigBlocks: [[Double]] = Array(repeating: [], count: 4)
    var hashes: [Set<Int>] = Array(repeating: [], count: 4)
    for block in 0..<9 {
        for v in 0..<4 {
            let bigIter = block < 3 ? 40 : 0  // calibrate big-text share
            let r = sweep(v, q); corpusBlocks[v].append(r.ms); hashes[v].insert(r.hash)
            if bigIter > 0 {
                var acc = 0.0; var h = 0
                for _ in 0..<bigIter { let b = big(v, q); acc += b.ms; h = h &* 31 &+ b.hash }
                bigBlocks[v].append(acc / Double(bigIter))
                hashes[v].insert(h)
            } else { let b = big(v, q); bigBlocks[v].append(b.ms); hashes[v].insert(b.hash) }
        }
        _ = block
    }
    print("query=\(q)")
    for v in 0..<4 {
        let cm = median(corpusBlocks[v]); let bm = median(bigBlocks[v])
        print(String(format: "  %@: corpus64 %.3f ms/sweep  big120KB %.3f ms/search  hashes=%d",
                     names[v], cm, bm, hashes[v].count))
    }
    // relative summary vs v0
    for v in 1..<4 {
        let cm = median(corpusBlocks[v]) / median(corpusBlocks[0]) - 1
        let bm = median(bigBlocks[v]) / median(bigBlocks[0]) - 1
        print(String(format: "  %@ vs v0: corpus %+.1f%%  big %+.1f%%", names[v], cm * 100, bm * 100))
    }
}
print("SCREEN_DONE")
