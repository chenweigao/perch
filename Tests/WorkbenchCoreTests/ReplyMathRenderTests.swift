import AppKit
import SwiftMath

/// Smoke check: the native typesetter really draws (the image is lazy, so draw
/// into a bitmap and count painted pixels). Bad TeX must report an error.
func checkMathRendering() {
    let math = MTMathImage(latex: #"x^2 + \frac{1}{2}"#, fontSize: 16, textColor: .black,
                           labelMode: .text, textAlignment: .left)
    let (error, image) = math.asImage()
    precondition(error == nil, "typeset failed: \(String(describing: error))")
    guard let image, image.size.width > 4, image.size.height > 4 else { fatalError("empty math image") }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { fatalError("no bitmap") }
    var painted = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 { painted += 1 }
        }
    }
    precondition(painted > 20, "math image drew \(painted) pixels")
    let bad = MTMathImage(latex: #"\notarealcommand"#, fontSize: 14, textColor: .black,
                          labelMode: .text, textAlignment: .left)
    let (badError, _) = bad.asImage()
    precondition(badError != nil, "bad TeX must surface an error")
    print("PASS: math rendering — typeset pixels, size, TeX error surface")
}
