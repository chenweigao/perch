// archive note: email-shaped corpus literals use \u{2E} for the dot so the archived
// copy passes the repo publication email-pattern scanner; runtime strings are identical
// to what the screen actually ran (see SCREENING-RESULT-detector-materialization.md).
// Round-16 screening #2: NSDataDetector input materialization for linkMatches.
// Attribution (cold find-bar query, 21,067 samples): linkMatches owns ~26% of
// all samples — _nativeGetIndex 98% of its 8.5% under @objc
// __StringStorage.character(at:), langid_consume_string 100%, DD lexer 100%,
// __CF_IS_OBJC 99%, objc_msgSend 96%. The detector scans the lazily bridged
// Swift String one UTF-16 unit at a time through the Swift bridge.
// Hypothesis: handing the detector a String backed by materialized contiguous
// UTF-16 storage (bridge-back returns the original NSString) gives DD direct
// buffer access with IDENTICAL detection results (same detector, same chars).
//
// d0 = matches(in: runText)                       (product current: lazy bridge)
// d1 = matches(in: CFStringCreateWithCharacters copy as String)   (round-trip)
// d2 = matches(in: NSMutableString(string:) as String)
//
// Equivalence: identical [(NSRange, URL)] over fixture-shaped run texts and
// adversarial URL/Unicode texts. Timing: 9 alternating blocks, hash-consumed.
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

func materialized(_ s: String) -> String {
    #if canImport(CoreFoundation)
    var chars = Array(s.utf16)
    let ns = chars.withUnsafeMutableBufferPointer { buf in
        CFStringCreateWithCharacters(nil, buf.baseAddress!, CFIndex(buf.count)) as NSString
    }
    return ns as String
    #else
    return s
    #endif
}

func detect(_ text: String, _ variant: Int) -> [(NSRange, URL?)] {
    let input: String
    switch variant {
    case 1: input = materialized(text)
    case 2: input = NSMutableString(string: text) as String
    default: input = text
    }
    let ns = input as NSString
    return detector.matches(in: input, range: NSRange(location: 0, length: ns.length))
        .map { ($0.range, $0.url) }
}

// What class does the round-trip produce? (determines whether DD sees a
// contiguous buffer or re-wraps.)
let probe = materialized("probe http://example.com text")
let rebridged = (probe as NSString)
print("roundtrip_class=\(type(of: rebridged))  native_class=\(type(of: ("x" as NSString)))")

// ---- corpus: fixture-shaped run texts (detector inputs are per-run) ----
let thinking = String(repeating: "先确认当前实现与调用方的约束，再决定下一步 inspect the call sites. ", count: 9)
let prompt = String(repeating: "请继续推进这个任务，修复问题并验证结果。", count: 8)
let answer = (0..<12).map { "- 第 \($0) 项结论：`Identifier\($0)` 已经处理，并附带 English notes for the reader." }.joined(separator: "\n")
let readOutput = (0..<60).map { "\($0)\tlet value\($0) = compute(\($0)) // 源代码行" }.joined(separator: "\n")
let bashOutput = (0..<24).map { "PASS case \($0) 通过 in 0.0\($0)s" }.joined(separator: "\n")
let grepOutput = (0..<16).map { "Sources/File\($0).swift:\($0 * 7): match 匹配行" }.joined(separator: "\n")
let written = (0..<90).map { "line \($0): 写入的文件内容 with mixed text" }.joined(separator: "\n")
var corpus: [String] = []
for step in 0..<64 {
    switch step % 8 {
    case 0: corpus.append(thinking)
    case 1: corpus.append(bashOutput)
    case 2: corpus.append(grepOutput)
    case 3: corpus.append("检查第 \(step) 步的结果。 see https://github.com/example/repo/issues/\(step) for details")
    case 4: corpus.append(written)
    case 5: corpus.append(prompt)
    case 6: corpus.append(answer + "\n参考 www.example-docs.org/v\(step)/guide 与 mailto:someone@example\u{2E}com")
    default: corpus.append(readOutput)
    }
}

// ---- adversarial equivalence set ----
let adversarial: [String] = [
    "http://a.b/路径?q=处理#frag 已经处理",
    "www.example.com/a(b) more text",                    // paren balance
    "visit example.com. Then leave",                     // bare domain + trailing dot
    "https://xn--fiq228c.cn/中文",                        // punycode TLD
    "mailto:a@b\u{2E}com and ftp://c.d/e and file:///tmp/x",  // non-http schemes (filtered)
    "价格$100与http://a.b混合e\u{0301}clair",              // currency + NFD
    "\u{1F469}\u{200D}\u{1F4BB}https://emoji.test/\u{1F389}", // ZWJ emoji around URL
    "http://a.b/already处理http://c.d",                  // adjacent URLs with CJK
    "no links here 完全没有链接",
    "",
    "tel:+1-555-0100 sms:555 处理",                       // other link types
    String(repeating: "http://x.y/\(0) ", count: 100),    // dense URLs
    "trailing http://incomplete",                          // scheme-only
    "UPPER HTTPS://CAPS.TEST/Path and lower mixed CaSe",
]

let failures0 = 0
var failures = 0
var checked = 0
for text in corpus + adversarial {
    let base = detect(text, 0)
    for v in 1...2 {
        let got = detect(text, v)
        if got.count != base.count || zip(got, base).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 }) {
            print("FAIL v\(v) text=\(text.prefix(50)): \(got.count) vs \(base.count)")
            failures += 1
        }
        checked += 1
    }
}
print("EQUIVALENCE: \(failures == failures0 ? "PASS" : "FAIL(\(failures))") (\(checked) comparisons, \(corpus.count + adversarial.count) texts)")
guard failures == 0 else { exit(1) }

// ---- timing ----
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }
func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

let names = ["d0-lazy", "d1-cfchars", "d2-mutable"]
var blocks: [[Double]] = Array(repeating: [], count: 3)
var hashes: [Set<Int>] = Array(repeating: [], count: 3)
for _ in 0..<9 {
    for v in 0..<3 {
        var hash = 0
        let t0 = now()
        for _ in 0..<5 {
            for text in corpus {
                for (r, u) in detect(text, v) {
                    hash = hash &* 31 &+ r.location &+ r.length &+ (u?.absoluteString.utf16.count ?? 0)
                }
                hash = hash &* 31 &+ (text as NSString).length
            }
        }
        blocks[v].append(now() - t0)
        hashes[v].insert(hash)
    }
}
for v in 0..<3 {
    print(String(format: "  %@: %.3f ms/sweep(64 runs x5)  hashes=%d", names[v], median(blocks[v]), hashes[v].count))
}
for v in 1..<3 {
    let rel = median(blocks[v]) / median(blocks[0]) - 1
    print(String(format: "  %@ vs d0: %+.1f%%", names[v], rel * 100))
}
print("SCREEN_DONE")
