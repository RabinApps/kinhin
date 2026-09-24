// Prints the CGWindowID of the frontmost window owned by "kinhin".
// Usage: swift winid.swift [ownerName]
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "kinhin"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let name = w[kCGWindowOwnerName as String] as? String ?? ""
    guard name == owner else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 99
    guard layer == 0 else { continue }
    if let id = w[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
}
exit(1)
