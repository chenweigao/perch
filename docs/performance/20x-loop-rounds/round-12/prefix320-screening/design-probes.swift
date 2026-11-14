// Round 12 design probes (read-only, standalone):
// 1) (" " + X).collapsedWhitespace == X.collapsedWhitespace identity
// 2) Substring byte access without materialization (utf8.withContiguousStorageIfAvailable)
// 3) String.utf8.count O(1)-ness proxy: correctness of "utf8.count <= 320 => Characters <= 320" fast path
func collapsed(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
let samples = ["这是一段 说明\n\n包含 **结论** 与 `identifier`", "plain ascii text with  spaces ", "  leading and trailing  ", "", " ", "emoji 👨‍👩‍👧 family  test", "tab\ta\rcrlf"]
var ok = true
for s in samples {
    let lhs = collapsed(" " + s)
    let rhs = collapsed(s)
    if lhs != rhs { ok = false; print("IDENTITY FAIL: \(s.debugDescription) lhs=\(lhs.debugDescription) rhs=\(rhs.debugDescription)") }
}
print("identity (' '+X)==X :", ok)
// 2) substring contiguous storage
let text = "这是一段用于验收的中文说明，包含 **结论**、`identifier` 与普通文本，混排 English words."
let sub = text.prefix(20)
if let n = sub.utf8.withContiguousStorageIfAvailable({ buf in
    var count = 0
    for b in buf { if b >= 0x80 { count += 1 } }
    return (buf.count, count)
}) {
    print("substring contiguous ok bytes=\(n.0) nonascii=\(n.1)")
} else {
    print("substring contiguous UNAVAILABLE")
}
// sliced substring (mid-string) also contiguous?
let mid = text.dropFirst(5).prefix(10)
print("mid-slice contiguous:", mid.utf8.withContiguousStorageIfAvailable({ $0.count }) != nil ? "yes" : "no")
// 3) fast-path soundness: utf8.count <= 320 implies Character count <= 320 (each Character >= 1 byte)
for s in samples + [text] {
    if s.utf8.count <= 320 && s.count > 320 { print("FASTPATH UNSOUND for \(s.debugDescription)") }
}
print("fastpath bound holds on samples; utf8.count=\(text.utf8.count) characters=\(text.count)")
// 4) index(offsetBy:limitedBy:) equals prefix()
let p1 = String(text.prefix(20))
let idx = text.index(text.startIndex, offsetBy: 20, limitedBy: text.endIndex) ?? text.endIndex
let p2 = String(text[text.startIndex..<idx])
print("prefix==index-range:", p1 == p2)
let short = "abc"
let idx2 = short.index(short.startIndex, offsetBy: 320, limitedBy: short.endIndex) ?? short.endIndex
print("short string limitedBy nil-path:", String(short[short.startIndex..<idx2]) == short)
