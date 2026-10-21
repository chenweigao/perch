#!/usr/bin/env swift
// Canonical geometry for the approved Perch mark. Regenerates SVG, PNG and ICNS inputs.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/Brand")
let iconset = root.appendingPathComponent("build/Perch.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Approved identity (2026-10 redesign): a sunset orb perched on a white branch.
// The branch is tangent to the orb; both sit on a near-black tile.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let branch = (from: NSPoint(x: 296, y: 640), to: NSPoint(x: 728, y: 640))
let branchWidth: CGFloat = 84
let orb = (center: NSPoint(x: 430, y: 476), radius: CGFloat(122))

let backgroundTop = "#1B1E26", backgroundBottom = "#121419"
let branchColor = "#FAFAF7"
let orbTop = "#FFD98E", orbBottom = "#FF7A59"
// Solid tone used where a gradient is unavailable (Icon Composer layer fill).
// Slightly deeper than the flat icon's mid-tone: the glass pipeline lightens it.
let orbSolid = "#FF8455"

func color(_ hex: String) -> NSColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func cgColor(_ hex: String) -> CGColor { color(hex).cgColor }

func gradientDef(id: String, top: String, bottom: String, x1: Int, y1: Int, x2: Int, y2: Int) -> String {
    """
    <linearGradient id="\(id)" gradientUnits="userSpaceOnUse" x1="\(x1)" y1="\(y1)" x2="\(x2)" y2="\(y2)">
      <stop offset="0" stop-color="\(top)"/><stop offset="1" stop-color="\(bottom)"/>
    </linearGradient>
    """
}
let branchLine = "<line x1=\"\(Int(branch.from.x))\" y1=\"\(Int(branch.from.y))\" x2=\"\(Int(branch.to.x))\" y2=\"\(Int(branch.to.y))\" stroke-width=\"\(Int(branchWidth))\" stroke-linecap=\"round\""
let orbCircle = "<circle cx=\"\(Int(orb.center.x))\" cy=\"\(Int(orb.center.y))\" r=\"\(Int(orb.radius))\""

func svg(icon: Bool) -> String {
    // Mono mark: everything in one ink color, on transparency.
    let ink = "#292D37"
    if !icon {
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Perch">
          \(branchLine) stroke="\(ink)"/>
          \(orbCircle) fill="\(ink)"/>
        </svg>
        """
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Perch">
    <defs>
      \(gradientDef(id: "tile", top: backgroundTop, bottom: backgroundBottom, x1: 512, y1: 100, x2: 512, y2: 924))
      \(gradientDef(id: "orb", top: orbTop, bottom: orbBottom, x1: 430, y1: 354, x2: 430, y2: 598))
    </defs>
      <rect x="100" y="100" width="824" height="824" rx="170" fill="url(#tile)"/>
      \(branchLine) stroke="\(branchColor)"/>
      \(orbCircle) fill="url(#orb)"/>
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
try layerSVG(["\(orbCircle) fill=\"\(orbSolid)\"/>"])
    .write(to: iconAssets.appendingPathComponent("orb.svg"), atomically: true, encoding: .utf8)
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
    "fill": ["solid": srgb(backgroundTop)],
    "groups": [
        [
            "layers": [
                glassLayer(name: "orb", file: "orb.svg", fill: ["solid": srgb("#FF8455")]),
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

    func fillVertical(_ path: CGPath, _ top: String, _ bottom: String, _ bbox: CGRect) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [cgColor(top), cgColor(bottom)] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: bbox.midX, y: bbox.minY),
                              end: CGPoint(x: bbox.midX, y: bbox.maxY),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }

    let tilePath = CGPath(roundedRect: tile, cornerWidth: 170, cornerHeight: 170, transform: nil)
    fillVertical(tilePath, backgroundTop, backgroundBottom, tile)

    color(branchColor).setStroke()
    let branchPath = NSBezierPath()
    branchPath.move(to: branch.from)
    branchPath.line(to: branch.to)
    branchPath.lineWidth = branchWidth
    branchPath.lineCapStyle = .round
    branchPath.stroke()

    let orbPath = CGPath(ellipseIn: CGRect(x: orb.center.x - orb.radius, y: orb.center.y - orb.radius,
                                           width: orb.radius * 2, height: orb.radius * 2), transform: nil)
    fillVertical(orbPath, orbTop, orbBottom, orbPath.boundingBox)

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
