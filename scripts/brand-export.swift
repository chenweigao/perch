import AppKit

@main
struct BrandExport {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Resources/Brand")
        let iconset = root.appendingPathComponent("build/Perch.iconset")
        let assets = output.appendingPathComponent("Perch.icon/Assets")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let color = "#E36D55"
        let svgBody = "M66 36C62 27 56 24 47 24C35 24 27 33 27 44C27 56 35 64 47 64C58 64 65 57 67 49L75 44L67 40C67 38 66.5 37 66 36Z"
        let svgBranch = "M23 79H77M47 64V79"
        let svgWing = "M37 43C39 52 47 54 54 46"
        func mark(_ ink: String) -> String {
            """
            <g fill="none" stroke="\(ink)" stroke-linecap="round" stroke-linejoin="round">
              <path d="\(svgBody)" stroke-width="5.4"/>
              <path d="\(svgBranch)" stroke-width="5.4"/>
              <path d="\(svgWing)" stroke-width="5.2"/>
            </g>
            """
        }
        func svg(_ body: String) -> String {
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100" role="img" aria-label="Perch">
              \(body)
            </svg>
            """
        }
        try svg("<rect x=\"9.765625\" y=\"9.765625\" width=\"80.46875\" height=\"80.46875\" rx=\"16.6015625\" fill=\"\(color)\"/><g transform=\"translate(9.765625 9.765625) scale(.8046875)\">\(mark("#FFFFFF"))</g>")
            .write(to: output.appendingPathComponent("Perch.svg"), atomically: true, encoding: .utf8)
        try svg(mark("#252B36")).write(to: output.appendingPathComponent("Perch-mark.svg"), atomically: true, encoding: .utf8)
        try svg(mark("#FFFFFF")).write(to: assets.appendingPathComponent("bird.svg"), atomically: true, encoding: .utf8)
        let json: [String: Any] = [
            "fill": ["solid": "srgb:0.89020,0.42745,0.33333,1.00000"],
            "groups": [[
                "layers": [["blend-mode": "normal", "fill": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"],
                            "glass": false, "hidden": false, "image-name": "bird.svg", "name": "bird",
                            "position": ["scale": 1, "translation-in-points": [0, 0]]]],
                "position": ["scale": 1, "translation-in-points": [0, 0]],
                "shadow": ["kind": "neutral", "opacity": 0.2]
            ]],
            "supported-platforms": ["squares": ["macOS"]]
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("Perch.icon/icon.json"))
        func png(points: Int, scale: Int) -> Data {
            let pixels = points * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let cg = context.cgContext
            cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            cg.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
            cg.translateBy(x: 0, y: 100)
            cg.scaleBy(x: 1, y: -1)
            let inset: CGFloat = 9.765625, side: CGFloat = 80.46875
            cg.setFillColor(NSColor(srgbRed: 227.0 / 255, green: 109.0 / 255, blue: 85.0 / 255, alpha: 1).cgColor)
            cg.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                cornerWidth: 16.6015625, cornerHeight: 16.6015625, transform: nil))
            cg.fillPath()
            cg.translateBy(x: inset, y: inset)
            cg.scaleBy(x: side / 100, y: side / 100)
            PerchBirdGeometry.draw(in: cg, ink: NSColor.white.cgColor, pixels: CGFloat(points))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.representation(using: .png, properties: [:])!
        }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try png(points: size, scale: scale).write(to: iconset.appendingPathComponent(name))
            }
        }
        try png(points: 1024, scale: 1).write(to: output.appendingPathComponent("Perch-1024.png"))
        print("Generated Perch bird SVG, PNG, Perch.icon and build/Perch.iconset")
    }
}
