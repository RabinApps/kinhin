import AppKit
import KinhinKit

#if DEBUG
    // Test-only accessors; compiled out of release builds.
    @MainActor
    extension ToolchainsViewController {
        func toggleToolForTesting(_ id: String, version: String = "", on: Bool = true) {
            working.tools[id] = on ? version : nil
            refreshState()
        }
        func toggleStackForTesting(_ id: String, on: Bool = true) {
            working.stacks[id] = on ? "" : nil
            refreshState()
        }
        func setShareCacheForTesting(_ on: Bool) { working.shareCache = on; refreshState() }
        var statusTextForTesting: String { statusLabel.stringValue }
        var applyEnabledForTesting: Bool { applyButton.isEnabled }
        var rebuildEnabledForTesting: [RuntimeID: Bool] { rebuildButtons.mapValues(\.isEnabled) }
        var workingForTesting: ToolchainsSelection { working }
        var renderedCountsForTesting: (tools: Int, stacks: Int) {
            (toolChecks.count, stackChecks.count)
        }
        var renderedToolFieldValuesForTesting: [String: String] {
            Dictionary(uniqueKeysWithValues: toolVersions.map { ($0.key, $0.value.stringValue) })
        }
        var renderedStackFieldValuesForTesting: [String: String] {
            Dictionary(uniqueKeysWithValues: stackVersions.map { ($0.key, $0.value.stringValue) })
        }
        var toolChecksForTesting: [String: NSButton] { toolChecks }
        var stackChecksForTesting: [String: NSButton] { stackChecks }
        var toolVersionsForTesting: [String: NSTextField] { toolVersions }
        var stackVersionsForTesting: [String: NSTextField] { stackVersions }
    }
#endif
