import KinhinKit
import SwiftUI

/// What a runtime is called and looks like, in one place: title, identity mark and tint for tart, Apple container,
/// Docker and the Host. The Fleet lanes, the Routing pools, the Budget bar and the Add Route choices all read it, so a
/// runtime can't be named or colored two ways. The marks match the CLI (`kinhin runtimes`).
struct RuntimeIdentity: Equatable {
    let runtime: RuntimeID
    /// The emoji that leads the title in pool and lane headings.
    let mark: String
    /// "Tart VMs (macOS)": the runtime and what it runs.
    let title: String
    /// The runtime's fixed color: its slice of the Budget bar, its dot on a slider row and on a Fleet lane.
    let tint: Color

    init(_ runtime: RuntimeID) {
        self.runtime = runtime
        switch runtime {
        case .tart:
            mark = "🍎"
            title = String(
                localized: "Tart VMs (macOS)", bundle: .l10n, comment: "Runtime name; Tart runs macOS VMs")
            tint = Palette.green
        case .appleContainer:
            mark = "🐧"
            title = String(
                localized: "Apple containers (Linux)", bundle: .l10n,
                comment: "Runtime name; Apple containers run Linux")
            tint = Palette.accent
        case .docker:
            mark = "🐳"
            title = String(localized: "Docker (Linux)", bundle: .l10n, comment: "Runtime name; Docker runs Linux")
            tint = Palette.teal
        case .host:
            mark = "🖥"
            title = String(
                localized: "Host (this Mac)", bundle: .l10n, comment: "Runtime name; jobs run directly on this Mac")
            tint = Palette.purple
        }
    }

    /// The mark, then the title: "🍎 Tart VMs (macOS)". Pool headings on the Routing screen use it.
    var markedTitle: String { "\(mark) \(title)" }

    /// The choice's wording in a runtime picker (the Add Route sheet), which says what each choice costs.
    var choiceTitle: String {
        switch runtime {
        case .tart:
            return String(
                localized: "tart — macOS VMs", bundle: .l10n, comment: "Runtime choice in the Add Route sheet")
        case .appleContainer:
            return String(
                localized: "Apple container — Linux", bundle: .l10n, comment: "Runtime choice in the Add Route sheet")
        case .docker:
            return String(localized: "Docker — Linux", bundle: .l10n, comment: "Runtime choice in the Add Route sheet")
        case .host:
            return String(
                localized: "Host — this Mac, no isolation", bundle: .l10n,
                comment: "Runtime choice in the Add Route sheet")
        }
    }
}

extension RuntimeID {
    /// The runtime's title, mark and tint.
    var identity: RuntimeIdentity { RuntimeIdentity(self) }
}

/// The runtime's leading dot: its tint, with the title as the accessibility label so the color is never the only cue.
struct RuntimeDot: View {
    let runtime: RuntimeID
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(runtime.identity.tint)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(verbatim: runtime.identity.title))
    }
}

#Preview("Runtime identities") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(RuntimeID.allCases, id: \.self) { runtime in
            HStack(spacing: Spacing.sm) {
                RuntimeDot(runtime: runtime)
                Text(verbatim: runtime.identity.markedTitle)
            }
        }
    }
    .padding(Spacing.lg)
}
