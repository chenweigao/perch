import Foundation
let s = "验证 é 测试" + String(repeating: " 增量", count: 100)
let sub = String(s.dropFirst(3))
var l = sub
var r = s
let eq = l.withUTF8 { a in r.withUTF8 { b in a.count == b.count && a.elementsEqual(b) } }
var t = sub
let n = t.withUTF8 { $0.count }
print("probe ok:", eq, n, sub.utf8.count)
