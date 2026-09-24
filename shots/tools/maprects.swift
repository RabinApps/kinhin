// Pixel-map utility: prints a coarse luminance map (2x downsampled ASCII) so
// you can locate real content rows/cols in a capture before probing precise
// rects. Characters: ' ' near-black … '#' near-white.
// Usage: swift maprects.swift <png> [step=40]
import Foundation
import CoreGraphics
import ImageIO

let path = CommandLine.arguments[1]
let step = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 40
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(1) }
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

let ramp: [Character] = [" ", "░", "▒", "▓", "#"]
print("size \(w)x\(h), step \(step) (rows are 2x px, origin top-left)")
for y in stride(from: 0, to: h, by: step) {
    var line = String(format: "%4d ", y)
    for x in stride(from: 0, to: w, by: step) {
        let i = (y * w + x) * 4
        let l = 0.2126 * Double(px[i]) + 0.7152 * Double(px[i+1]) + 0.0722 * Double(px[i+2])
        let idx = min(4, max(0, Int(l / 51)))
        line.append(ramp[idx])
    }
    print(line)
}
