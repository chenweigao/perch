import Foundation
var foundationOnly: [UInt32] = []
var mirrorOnly: [UInt32] = []
func isWhitespaceScalar(_ s: UInt32) -> Bool {
    s == 0x20 || (0x09...0x0D).contains(s) ||
    [0x85, 0xA0, 0x1680, 0x2000,0x2001,0x2002,0x2003,0x2004,0x2005,0x2006,0x2007,0x2008,0x2009,0x200A,
     0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(s)
}
let ws = CharacterSet.whitespacesAndNewlines
var u: UInt32 = 0
while u <= 0x10FFFF {
    if (0xD800...0xDFFF).contains(u) { u += 1; continue }
    guard let scalar = Unicode.Scalar(u) else { u += 1; continue }
    let inFoundation = ws.contains(scalar)
    let inMirror = isWhitespaceScalar(u)
    let stdlib = Character(String(scalar)).isWhitespace
    if inFoundation != inMirror {
        if inFoundation { foundationOnly.append(u) } else { mirrorOnly.append(u) }
        print(String(format: "DIFF U+%04X foundation=%d mirror=%d stdlibIsWS=%d", u, inFoundation ? 1:0, inMirror ? 1:0, stdlib ? 1:0))
    }
    u += 1
}
print("foundationOnly=\(foundationOnly.count) mirrorOnly=\(mirrorOnly.count)")
print("trim200B=[\("a\u{200B}".trimmingCharacters(in: .whitespacesAndNewlines))]")
