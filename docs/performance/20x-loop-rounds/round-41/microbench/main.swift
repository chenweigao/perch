import Foundation
let base = String(repeating: "第 0 段结论:实现满足约束,继续推进验证与收尾工作。", count: 40)
var current = base
var iterations = 0
// measure hasPrefix
let n = 2000
var t = Date()
for i in 0..<n {
    current = base + String(i % 10)
    if current.hasPrefix(base) { iterations += 1 }
}
let hpTime = Date().timeIntervalSince(t) / Double(n) * 1e6
// measure byte prefix
func bytePrefix(_ whole: String, _ prefix: String) -> Bool {
    var w = whole; var p = prefix
    return w.withUTF8 { wb in p.withUTF8 { pb in
        guard wb.count >= pb.count else { return false }
        for i in 0..<pb.count where wb[i] != pb[i] { return false }
        return true
    }}
}
t = Date()
var iterations2 = 0
for i in 0..<n {
    current = base + String(i % 10)
    if bytePrefix(current, base) { iterations2 += 1 }
}
let bpTime = Date().timeIntervalSince(t) / Double(n) * 1e6
print("bytes=\(base.utf8.count) hasPrefix=\(String(format: "%.2f", hpTime))us bytePrefix=\(String(format: "%.2f", bpTime))us iters=\(iterations)/\(iterations2)")
