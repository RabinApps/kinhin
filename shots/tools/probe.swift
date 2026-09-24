// Usage: swift probe.swift <png> contrast x y w h [x y w h ...]
// For each rect: finds the extreme-luminance pixels (text antialiasing
// extremes) and the median luminance (background), prints the WCAG contrast
// ratio of text-vs-background plus the sampled colors.
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("cannot load \(args.count > 1 ? args[1] : "?")\n".data(using: .utf8)!)
    exit(1)
}

let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

func lum(_ r: Int, _ g: Int, _ b: Int) -> Double {
    func chan(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * chan(Double(r) / 255) + 0.7152 * chan(Double(g) / 255) + 0.0722 * chan(Double(b) / 255)
}
func ratio(_ l1: Double, _ l2: Double) -> Double {
    let hi = max(l1, l2), lo = min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)
}

// No flip: rect coords are TOP-LEFT 2x pixels (matching audit.py and maps).
func sample(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}

var index = 3
while index + 3 < args.count {
    let x = Int(args[index])!, y = Int(args[index + 1])!, rw = Int(args[index + 2])!, rh = Int(args[index + 3])!
    index += 4
    var lums: [Double] = []
    var darkest = (255, 255, 255), lightest = (0, 0, 0)
    var darkL = 2.0, lightL = -1.0
    let x0 = max(0, x), y0 = max(0, y), x1 = min(w - 1, x + rw - 1), y1 = min(h - 1, y + rh - 1)
    guard x0 <= x1, y0 <= y1 else { print("rect \(x),\(y) \(rw)x\(rh): out of image"); continue }
    for yy in stride(from: y0, through: y1, by: max(1, rh / 60)) {
        for xx in stride(from: x0, through: x1, by: max(1, rw / 60)) {
            let (r, g, b) = sample(xx, yy)
            let l = lum(r, g, b)
            lums.append(l)
            if l < darkL { darkL = l; darkest = (r, g, b) }
            if l > lightL { lightL = l; lightest = (r, g, b) }
        }
    }
    lums.sort()
    let median = lums[lums.count / 2]
    // Text is whichever extreme is farther from the median luminance.
    let textL = abs(darkL - median) > abs(lightL - median) ? darkL : lightL
    let text = abs(darkL - median) > abs(lightL - median) ? darkest : lightest
    let r = ratio(textL, median)
    let hex = { (c: (Int, Int, Int)) -> String in String(format: "#%02x%02x%02x", c.0, c.1, c.2) }
    let verdict = r >= 4.5 ? "AA" : (r >= 3.0 ? "AA-large-only" : "FAIL")
    print(String(format: "rect \(x),\(y) \(rw)x\(rh): contrast %.2f:1 [\(verdict)] text \(hex(text)) L=%.3f bg L=%.3f", r, textL, median))
}
