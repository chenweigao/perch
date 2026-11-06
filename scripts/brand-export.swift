import AppKit

@main
struct BrandExport {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Resources/Brand")
        let iconset = root.appendingPathComponent("build/Perch.iconset")
        let assets = output.appendingPathComponent("Perch.icon/Assets")
        let appResources = root.appendingPathComponent("Sources/AgentWorkbench/Resources")
        for directory in [iconset, assets, appResources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Keep the approved raster master unchanged: tracing would lose the woodcut grain.
        let master = try Data(contentsOf: output.appendingPathComponent("Perch-mark.png"))
        let image = NSImage(data: master)!
        try master.write(to: assets.appendingPathComponent("terrain.png"))
        let json: [String: Any] = [
            "fill": ["solid": "srgb:0.98039,0.96471,0.93725,1.00000"],
            "groups": [[
                "layers": [["blend-mode": "normal", "glass": false, "hidden": false,
                            "image-name": "terrain.png", "name": "woodcut terrain",
                            "position": ["scale": 1, "translation-in-points": [0, 0]]]],
                "position": ["scale": 1, "translation-in-points": [0, 0]],
                "shadow": ["kind": "neutral", "opacity": 0]
            ]],
            "supported-platforms": ["squares": ["macOS"]]
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("Perch.icon/icon.json"))

        // In-app marks use a tightly cropped alpha template in the current ink color.
        let source = NSBitmapImageRep(data: master)!
        precondition(source.bitsPerSample == 8 && source.samplesPerPixel == 4 && source.hasAlpha)
        let bytes = source.bitmapData!
        var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide where bytes[y * source.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let cropped = NSBitmapImageRep(cgImage: source.cgImage!.cropping(to: bounds)!)
        try cropped.representation(using: .png, properties: [:])!
            .write(to: appResources.appendingPathComponent("Perch-mark.png"))

        func png(points: Int, scale: Int) -> Data {
            let pixels = points * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let side = CGFloat(pixels)
            let tile = CGRect(x: side * 0.09765625, y: side * 0.09765625,
                              width: side * 0.8046875, height: side * 0.8046875)
            NSColor(srgbRed: 250.0 / 255, green: 246.0 / 255, blue: 239.0 / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: side * 0.166015625, yRadius: side * 0.166015625).fill()
            image.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
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
        print("Generated woodcut terrain PNG, app template, Perch.icon and build/Perch.iconset")
    }
}
