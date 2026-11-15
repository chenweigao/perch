import Foundation
// Corrected probe (re-review F1'): compare RAW BYTES, not canonical ==.
// Canonical equality holds even when decomposition changed the scalars,
// which invalidated the first probe's "SELF" conclusions.
for v: UInt32 in [0xFA55, 0xFA8E, 0xF96A, 0x2F00, 0x2F800] {
    let s = String(Unicode.Scalar(v)!)
    let d = s.decomposedStringWithCanonicalMapping
    let changed = Array(d.utf8) != Array(s.utf8)
    print(String(format: "U+%05X bytes_changed=%@ decomposition=%@", v, changed ? "YES" : "NO",
          d.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: "+")))
}
var changing = 0
var scan: UInt32 = 0xF900
while scan <= 0xFAFF {
    if let sc = Unicode.Scalar(scan) {
        let s = String(sc)
        if Array(s.decomposedStringWithCanonicalMapping.utf8) != Array(s.utf8) { changing += 1 }
    }
    scan += 1
}
print("F900-FAFF byte-changing under canonical decomposition:", changing)
print("contains 冲+FA55 vs 冲突:", "\u{51B2}\u{FA55}".contains("冲突"))
