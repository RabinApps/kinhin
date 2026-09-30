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

/// All values for a repeatable `--flag <value>` argument, in order.
func allFlags(_ name: String, in args: [String]) -> [String] {
    var values: [String] = []
    var index = args.startIndex
    while let found = args[index...].firstIndex(of: name) {
        let valueIndex = args.index(after: found)
        guard valueIndex < args.endIndex else { break }
        values.append(args[valueIndex])
        index = args.index(after: valueIndex)
    }
    return values
}
