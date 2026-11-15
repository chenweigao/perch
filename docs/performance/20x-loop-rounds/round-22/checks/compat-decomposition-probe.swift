import Foundation
for v: UInt32 in [0xFA55, 0xFA8E, 0xF96A, 0x2F00, 0x2F800] {
    let s = String(Unicode.Scalar(v)!)
    let d = s.decomposedStringWithCanonicalMapping
    print(String(format: "U+%04X decomposed=%@", v, d == s ? "SELF" : d.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: "+")))
}
let fold1 = "\u{51B2}\u{FA55}".contains("冲突")
let fold2 = "\u{FA8E}\u{7D22}".contains("搜索")
let fold3 = "冲\u{FA55}".lowercased().contains("冲突")
print("contains 冲+FA55 vs 冲突:", fold1, "| FA8E+索 vs 搜索:", fold2, "| lowercased chain:", fold3)
var bridges = 0
var scan: UInt32 = 0xF900
while scan <= 0xFAFF {
    if let sc = Unicode.Scalar(scan) {
        let s = String(sc)
        if s.decomposedStringWithCanonicalMapping != s { bridges += 1 }
    }
    scan += 1
}
print("F900-FAFF decomposing count:", bridges)
