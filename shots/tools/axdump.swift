// AX tree dumper: prints role|frame|title|value for every element under
// the kinhin app's frontmost window.
// Usage: swift axdump.swift [outFile]
import Foundation
import ApplicationServices

func axValue(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attr as CFString, &v)
    return v
}
func str(_ v: CFTypeRef?) -> String {
    guard let v else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    guard let list = axValue(e, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
    return list
}

func dump(_ e: AXUIElement, depth: Int, into out: NSMutableString) {
    let role = str(axValue(e, kAXRoleAttribute))
    let title = str(axValue(e, kAXTitleAttribute))
    let value = str(axValue(e, kAXValueAttribute)).replacingOccurrences(of: "\n", with: " ⏎ ")
    let desc = str(axValue(e, kAXDescriptionAttribute))
    var frame = CGRect.zero
    if let v = axValue(e, kAXPositionAttribute) {
        var point = CGPoint.zero
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgPoint, &point) {
            frame.origin = point
        }
    }
    if let v = axValue(e, kAXSizeAttribute) {
        var size = CGSize.zero
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &size) {
            frame.size = size
        }
    }
    let pad = String(repeating: "  ", count: depth)
    var label = title.isEmpty ? value : title
    if !desc.isEmpty { label += " 〈\(desc)〉" }
    out.append(String(format: "%@%@ [%.0f,%.0f %.0fx%.0f] %@\n", pad, role, frame.origin.x, frame.origin.y, frame.width, frame.height, label))
    if depth > 12 { return }
    for c in children(e) { dump(c, depth: depth + 1, into: out) }
}

let pid = Int32(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0")!
let app = AXUIElementCreateApplication(pid)
guard let winList = axValue(app, kAXWindowsAttribute) as? [AXUIElement], let win = winList.first else {
    FileHandle.standardError.write("no window for pid \(pid)\n".data(using: .utf8)!)
    exit(1)
}
let out = NSMutableString()
dump(win, depth: 0, into: out)
if CommandLine.arguments.count > 2 {
    try! out.write(toFile: CommandLine.arguments[2], atomically: true, encoding: String.Encoding.utf8.rawValue)
    print("wrote \(CommandLine.arguments[2]) (\(out.length) chars)")
} else {
    print(out)
}
