// Minimal AppMain stand-in for the capture harness: keeps the crash-alert
// symbol the app sources reference, without @main (harness is the entry).
import AppKit

func kinhinPresentCrashAlert(reason: String) {
    NSAlert(error: NSError(domain: "kinhin", code: -1,
                           userInfo: [NSLocalizedDescriptionKey: reason])).runModal()
}
