import Foundation
let text = String(repeating: "第 0 段结论:实现满足约束,继续推进验证与收尾工作。", count: 40)
let bytes = Array(text.utf8)
let n = 3000
var t = Date()
var sink = 0
for _ in 0..<n { let s = String(decoding: bytes, as: UTF8.self); sink += s.utf8.count }
let arrTime = Date().timeIntervalSince(t) / Double(n) * 1e6
t = Date()
for _ in 0..<n { let s = String(decoding: bytes[0..<bytes.count], as: UTF8.self); sink += s.utf8.count }
let sliceTime = Date().timeIntervalSince(t) / Double(n) * 1e6
t = Date()
for _ in 0..<n {
    let s = bytes.withUnsafeBufferPointer { buf in String(decoding: buf, as: UTF8.self) }
    sink += s.utf8.count
}
let bufTime = Date().timeIntervalSince(t) / Double(n) * 1e6
print("bytes=\(bytes.count) array=\(String(format:"%.2f",arrTime))us slice=\(String(format:"%.2f",sliceTime))us buffer=\(String(format:"%.2f",bufTime))us sink=\(sink)")
