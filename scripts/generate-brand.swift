#!/usr/bin/env swift
// Canonical geometry for the approved Perch mark. Regenerates SVG, PNG and ICNS inputs.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/Brand")
let iconset = root.appendingPathComponent("build/Perch.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Approved identity (2026-11 line redesign): a sun ring floating over a branch,
// both white lines, on a flat tile in the brand coral. Same composition as the
// in-app PerchLineMark (Sources/AgentWorkbench/PerchBusyIndicator.swift) at icon
// weight: the sun left of centre, one gap between the ring and the branch.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let lineWidth: CGFloat = 64
let branch = (from: NSPoint(x: 282, y: 700), to: NSPoint(x: 742, y: 700))
let sun = (center: NSPoint(x: 440, y: 470), radius: CGFloat(140))

// Two colors, no gradients: the brand coral (WorkbenchTheme.Brand.sun) and white.
let tileColor = "#FF7A59"
let branchColor = "#FFFFFF"
let sunColor = "#FFFFFF"

func color(_ hex: String) -> NSColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func cgColor(_ hex: String) -> CGColor { color(hex).cgColor }

let branchLine = "<line x1=\"\(Int(branch.from.x))\" y1=\"\(Int(branch.from.y))\" x2=\"\(Int(branch.to.x))\" y2=\"\(Int(branch.to.y))\" stroke-width=\"\(Int(lineWidth))\" stroke-linecap=\"round\""
let sunRing = "<circle cx=\"\(Int(sun.center.x))\" cy=\"\(Int(sun.center.y))\" r=\"\(Int(sun.radius))\" fill=\"none\" stroke-width=\"\(Int(lineWidth))\""

func svg(icon: Bool) -> String {
    // Mono mark: everything in one ink color, on transparency.
    let ink = "#292D37"
    if !icon {
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Perch">
          \(branchLine) stroke="\(ink)"/>
          \(sunRing) stroke="\(ink)"/>
        </svg>
        """
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Perch">
      <rect x="100" y="100" width="824" height="824" rx="170" fill="\(tileColor)"/>
      \(branchLine) stroke="\(branchColor)"/>
      \(sunRing) stroke="\(sunColor)"/>
    </svg>
    """
}
try svg(icon: true).write(to: output.appendingPathComponent("Perch.svg"), atomically: true, encoding: .utf8)
try svg(icon: false).write(to: output.appendingPathComponent("Perch-mark.svg"), atomically: true, encoding: .utf8)

// Liquid Glass icon package (Icon Composer document). One full-canvas SVG per
// layer; the system supplies the backplate, clipping, lighting and tinting.
func layerSVG(_ shapes: [String]) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      \(shapes.joined(separator: "\n  "))
    </svg>
    """
}
let iconPackage = output.appendingPathComponent("Perch.icon")
let iconAssets = iconPackage.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: iconAssets, withIntermediateDirectories: true)
try layerSVG(["\(sunRing) stroke=\"\(sunColor)\"/>"])
    .write(to: iconAssets.appendingPathComponent("sun.svg"), atomically: true, encoding: .utf8)
try layerSVG(["\(branchLine) stroke=\"\(branchColor)\"/>"])
    .write(to: iconAssets.appendingPathComponent("branch.svg"), atomically: true, encoding: .utf8)

func srgb(_ hex: String) -> String {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    let r = Double((value >> 16) & 255) / 255, g = Double((value >> 8) & 255) / 255, b = Double(value & 255) / 255
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b)
}
func glassLayer(name: String, file: String, fill: [String: String]) -> [String: Any] {
    [
        "blend-mode": "normal",
        "fill": fill,
        "glass": false,
        "hidden": false,
        "image-name": file,
        "name": name,
        "position": ["scale": 1, "translation-in-points": [0, 0]],
    ]
}
let iconJSON: [String: Any] = [
    "fill": ["solid": srgb(tileColor)],
    "groups": [
        [
            "layers": [
                glassLayer(name: "sun", file: "sun.svg", fill: ["solid": srgb(sunColor)]),
                glassLayer(name: "branch", file: "branch.svg", fill: ["solid": srgb(branchColor)]),
            ],
            "shadow": ["kind": "neutral", "opacity": 0.2],
            "position": ["scale": 1.25, "translation-in-points": [0, 0]],
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
let iconData = try JSONSerialization.data(withJSONObject: iconJSON, options: [.prettyPrinted, .sortedKeys])
try iconData.write(to: iconPackage.appendingPathComponent("icon.json"))

func png(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    cg.translateBy(x: 0, y: 1024)
    cg.scaleBy(x: 1, y: -1)

    let tilePath = CGPath(roundedRect: tile, cornerWidth: 170, cornerHeight: 170, transform: nil)
    cg.addPath(tilePath)
    cg.setFillColor(cgColor(tileColor))
    cg.fillPath()

    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    cg.setStrokeColor(cgColor(branchColor))
    cg.move(to: branch.from)
    cg.addLine(to: branch.to)
    cg.strokePath()

    cg.setStrokeColor(cgColor(sunColor))
    cg.strokeEllipse(in: CGRect(x: sun.center.x - sun.radius, y: sun.center.y - sun.radius,
                                width: sun.radius * 2, height: sun.radius * 2))

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try png(pixels: 1024).write(to: output.appendingPathComponent("Perch-1024.png"))
print("Generated Perch SVG, PNG, Perch.icon and build/Perch.iconset")
