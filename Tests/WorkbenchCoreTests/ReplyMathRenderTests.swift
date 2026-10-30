import AppKit
import SwiftMath
import WorkbenchCore

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
    let reportedSources = [
        #"\[\frac{12\times4\times P(S)}{S}\]"#,
        #"\[\boxed{F(S)=11.6412088+F_{\rm attn}(S)+1.536\times10^{-6}S}\]"#,
        #"\[P(S)=\begin{cases}S(S+1)/2, & S\le W\\W(W+1)/2+(S-W)W, & S>W\end{cases}\]"#,
    ]
    for source in reportedSources {
        let blocks = ReplyDocument.parse(source)
        guard blocks.count == 1, case .math(let latex) = blocks[0] else {
            fatalError("expected backslash-delimited math, got \(blocks)")
        }
        let reportedMath = MTMathImage(latex: ReplyMath.boxedContent(latex) ?? latex,
                                       fontSize: 16, textColor: .black,
                                       labelMode: .display, textAlignment: .left)
        let (reportedError, reportedImage) = reportedMath.asImage()
        precondition(reportedError == nil && reportedImage != nil,
                     "reported formula typeset failed: \(String(describing: reportedError))")
    }
    let bad = MTMathImage(latex: #"\notarealcommand"#, fontSize: 14, textColor: .black,
                          labelMode: .text, textAlignment: .left)
    let (badError, _) = bad.asImage()
    precondition(badError != nil, "bad TeX must surface an error")
    print("PASS: math rendering — typeset pixels, size, TeX error surface")
}
