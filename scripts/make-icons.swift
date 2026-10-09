#!/usr/bin/env swift
// Regenerates every raster/vector brand asset from the geometry in assets/brand/icon.svg:
//   assets/brand/AppIcon.iconset, assets/brand/AppIcon.icns,
//   website/public/{favicon.svg,mark.svg,favicon-32.png,apple-touch-icon.png,og.png}
// Run from anywhere: swift scripts/make-icons.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appendingPathComponent("assets/brand")
let publicDir = root.appendingPathComponent("website/public")
let iconset = brand.appendingPathComponent("AppIcon.iconset")
let fm = FileManager.default

/// Draws the icon (white squircle + black ring) on a canvas, centered and scaled to fit.
func render(width: Int, height: Int, body: (CGContext, CGFloat, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    body(ctx.cgContext, CGFloat(width), CGFloat(height))
    return rep.representation(using: .png, properties: [:])!
}

func drawIcon(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
    let s = min(w, h) / 1024
    let ox = (w - 1024 * s) / 2, oy = (h - 1024 * s) / 2
    let body = CGRect(x: ox + 100 * s, y: oy + 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.addPath(path)
    c.fillPath()
    c.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    c.setLineWidth(max(1, s))
    c.addPath(path)
    c.strokePath()
    c.setStrokeColor(CGColor(gray: 0, alpha: 1))
    c.setLineWidth(32 * s)
    c.strokeEllipse(in: CGRect(x: ox + 272 * s, y: oy + 272 * s, width: 480 * s, height: 480 * s))
}

func write(_ data: Data, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

try? fm.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try write(render(width: px, height: px, body: drawIcon), iconset.appendingPathComponent(name))
    }
}

let icns = Process()
icns.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icns.arguments = ["-c", "icns", iconset.path, "-o", brand.appendingPathComponent("AppIcon.icns").path]
try icns.run()
icns.waitUntilExit()
guard icns.terminationStatus == 0 else { fatalError("iconutil failed") }

try write(render(width: 32, height: 32, body: drawIcon), publicDir.appendingPathComponent("favicon-32.png"))
try write(render(width: 180, height: 180, body: drawIcon), publicDir.appendingPathComponent("apple-touch-icon.png"))
try write(
    render(width: 1200, height: 630) { c, w, h in
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setStrokeColor(CGColor(gray: 0, alpha: 1))
        c.setLineWidth(19)
        c.strokeEllipse(in: CGRect(x: w / 2 - 140.5, y: h / 2 - 140.5, width: 281, height: 281))
    }, publicDir.appendingPathComponent("og.png"))
try? fm.removeItem(at: publicDir.appendingPathComponent("favicon.svg"))
try fm.copyItem(at: brand.appendingPathComponent("icon.svg"), to: publicDir.appendingPathComponent("favicon.svg"))
try? fm.removeItem(at: publicDir.appendingPathComponent("mark.svg"))
try fm.copyItem(at: brand.appendingPathComponent("mark.svg"), to: publicDir.appendingPathComponent("mark.svg"))
print("brand assets regenerated")
