import AppKit
import Vision
func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
func pathD(_ p: CGPath, w: CGFloat, h: CGFloat) -> String {
    var s = ""
    p.applyWithBlock { e in
        let el = e.pointee; let q = el.points
        func X(_ i: Int) -> String { f(q[i].x * w) }
        func Y(_ i: Int) -> String { f((1 - q[i].y) * h) }
        switch el.type {
        case .moveToPoint: s += "M\(X(0)) \(Y(0)) "
        case .addLineToPoint: s += "L\(X(0)) \(Y(0)) "
        case .addQuadCurveToPoint: s += "Q\(X(0)) \(Y(0)) \(X(1)) \(Y(1)) "
        case .addCurveToPoint: s += "C\(X(0)) \(Y(0)) \(X(1)) \(Y(1)) \(X(2)) \(Y(2)) "
        case .closeSubpath: s += "Z "
        @unknown default: break
        }
    }
    return s
}
var out: [String: [String: Any]] = [:]
for n in CommandLine.arguments.dropFirst() {
    let cfg = NSImage.SymbolConfiguration(pointSize: 160, weight: .regular, scale: .medium)
    guard let base = NSImage(systemSymbolName: n, accessibilityDescription: nil), let img = base.withSymbolConfiguration(cfg) else { FileHandle.standardError.write("MISSING \(n)\n".data(using: .utf8)!); continue }
    let pad: CGFloat = 8
    let W = Int(img.size.width + pad * 2), H = Int(img.size.height + pad * 2)
    let cs = CGColorSpaceCreateDeviceGray()
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // draw symbol as a black mask
    var rect = CGRect(x: pad, y: pad, width: img.size.width, height: img.size.height)
    if let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
        ctx.saveGState(); ctx.clip(to: rect, mask: cg); ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(rect); ctx.restoreGState()
    }
    let cgimg = ctx.makeImage()!
    let req = VNDetectContoursRequest()
    req.detectsDarkOnLight = true; req.contrastAdjustment = 1.0; req.maximumImageDimension = 1024
    try! VNImageRequestHandler(cgImage: cgimg, options: [:]).perform([req])
    let obs = req.results!.first!
    // target 16pt-ish icon height
    let scale: CGFloat = 16.0 / CGFloat(H)
    let tw = CGFloat(W) * scale, th = CGFloat(H) * scale
    let simplified = (try? obs.normalizedPath.copy()) ?? obs.normalizedPath
    out[n] = ["w": Double(tw), "h": Double(th), "d": pathD(simplified, w: tw, h: th)]
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
print(String(data: data, encoding: .utf8)!)
