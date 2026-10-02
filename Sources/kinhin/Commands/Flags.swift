import Foundation
import KinhinKit

// A tiny flag parser: --key value / --flag.
func flag(_ name: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func hasFlag(_ name: String, in args: [String]) -> Bool {
    args.contains(name)
}
