// Round-24 probe: enumerate whitespace-adjacent fusion gaps of the product's
// beginsBindingMark property logic over all scalars, faithfully replicating
// the product decision path (never-binding prefilter -> ZWJ/isGraphemeExtend
// -> Mn/Mc/Me). Semantics-only probe: runs compiled on Linux, interpreter
// mode on macOS (round-22 compat-probe precedent).
import Foundation

func neverBinding(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x11FF, 0x3001...0x3029, 0x3030...0x303E,
         0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FF,
         0x3105...0x312F, 0x3131...0x318E, 0x3400...0x4DBF,
         0x4E00...0x9FFF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
         0xFF01...0xFF60, 0xFF61...0xFF9D, 0xFFA0...0xFFDC:
        return true
    default:
        return false
    }
}
func productDetected(_ value: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(value) else { return true }
    if neverBinding(value) { return false }
    if value == 0x200D || scalar.properties.isGraphemeExtend { return true }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return false
    }
}
func hex(_ v: UInt32) -> String { String(format: "U+%04X", v) }

var gaps: [UInt32] = []        // fuses with preceding space but product goes fast -> contract violation
var overStrict: [UInt32] = []  // product falls back to strict but no fusion -> safe direction
var probe: UInt32 = 0x80
while probe < 0x110000 {
    if probe >= 0xD800 && probe <= 0xDFFF { probe = 0xE000; continue }
    if let scalar = Unicode.Scalar(probe) {
        let fuses = (" " + String(scalar)).count == 1
        let isWS = scalar.properties.isWhitespace
        let detected = productDetected(probe) || isWS  // non-ASCII whitespace also forces strict in product
        if fuses && !detected { gaps.append(probe) }
        if detected && !fuses && !isWS { overStrict.append(probe) }
    }
    probe += 1
}
print("platform-gaps:", gaps.count)
print("gap-scalars:", gaps.map(hex).joined(separator: " "))
print("over-strict:", overStrict.count)
print("over-strict-scalars(first 60):", overStrict.prefix(60).map(hex).joined(separator: " "))
// spot-check the contract violation shape for each gap scalar
for g in gaps {
    let s = String(Unicode.Scalar(g)!)
    let text = "a  " + s + " b"   // double space before the gap scalar
    let strict = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    print("gap \(hex(g)): strict=\(strict.debugDescription)")
}
