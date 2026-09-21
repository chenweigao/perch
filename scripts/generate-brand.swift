#!/usr/bin/env swift
// Canonical geometry for the approved Perch mark. Regenerates SVG, PNG and ICNS inputs.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/Brand")
let iconset = root.appendingPathComponent("build/Perch.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let stem = NSRect(x: 350, y: 254, width: 70, height: 526)
let cursor = NSRect(x: 485, y: 554, width: 200, height: 56)
let chevron = [NSPoint(x: 520, y: 284), NSPoint(x: 650, y: 378), NSPoint(x: 520, y: 472)]
let background = "#292D37", foreground = "#FAFAF7", green = "#55E58B"
func color(_ hex: String) -> NSColor {
    let value = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}
func rectSVG(_ rect: NSRect, radius: Int, fill: String) -> String {
    "<rect x=\"\(Int(rect.minX))\" y=\"\(Int(rect.minY))\" width=\"\(Int(rect.width))\" height=\"\(Int(rect.height))\" rx=\"\(radius)\" fill=\"\(fill)\"/>"
}
func svg(icon: Bool) -> String {
    let ink = icon ? foreground : background
    let points = chevron.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Perch">
      \(icon ? rectSVG(tile, radius: 170, fill: background) : "")
      \(rectSVG(stem, radius: 14, fill: ink))
      <polyline points="\(points)" fill="none" stroke="\(icon ? green : background)" stroke-width="70" stroke-linecap="round" stroke-linejoin="round"/>
      \(rectSVG(cursor, radius: 12, fill: ink))
    </svg>
    """.replacingOccurrences(of: "  \n", with: "")
}
try svg(icon: true).write(to: output.appendingPathComponent("Perch.svg"), atomically: true, encoding: .utf8)
try svg(icon: false).write(to: output.appendingPathComponent("Perch-mark.svg"), atomically: true, encoding: .utf8)
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
    color(background).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 170, yRadius: 170).fill()
    color(foreground).setFill()
    NSBezierPath(roundedRect: stem, xRadius: 14, yRadius: 14).fill()
    NSBezierPath(roundedRect: cursor, xRadius: 12, yRadius: 12).fill()
    color(green).setStroke()
    let path = NSBezierPath()
    path.move(to: chevron[0])
    for point in chevron.dropFirst() { path.line(to: point) }
    path.lineWidth = 70; path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.stroke()
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
print("Generated Perch SVG, PNG and build/Perch.iconset")
