import Foundation
import KinhinKit

/// The full help screen (`kinhin help`), generated from `CommandCatalog`. One
/// call site for the printer and tests alike. The checked-in copy that the
/// docs generator reads is `scripts/golden/cli-help.txt`; `HelpTextTests`
/// fails when the two drift.
func helpText() -> String {
    HelpRenderer.overview()
}

/// The help for `kinhin help <command…>` / `kinhin <command…> --help`; the
/// full screen when the topic names no command.
func helpText(for topic: [String]) -> String {
    let words = topic.filter { !$0.hasPrefix("-") }
    guard !words.isEmpty, let invocation = try? CommandResolver.resolve(words) else { return helpText() }
    return HelpRenderer.page(for: invocation.helpSpec, path: invocation.helpPath)
}

func printHelp(toStandardError: Bool = false) {
    if toStandardError {
        printError(helpText())
    } else {
        print(helpText())
    }
}
