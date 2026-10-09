import KinhinKit
import SwiftUI

/// A small "untested" tag for a forge or runtime that has not been run against
/// the real service (see `MaturityTable`). Draws nothing for a live-tested one.
struct MaturityBadge: View {
    let maturity: Maturity

    init(_ maturity: Maturity) { self.maturity = maturity }
    init(forge: ForgeID) { self.maturity = MaturityTable.maturity(of: forge) }
    init(runtime: RuntimeID) { self.maturity = MaturityTable.maturity(of: runtime) }

    @State private var showingWarning = false

    var body: some View {
        if maturity.isUntested {
            Button {
                showingWarning.toggle()
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(StatusStyle.warn.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Untested. Click for details.")
            .accessibilityLabel("untested")
            .popover(isPresented: $showingWarning, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Untested", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(StatusStyle.warn.color)
                    Text(
                        "Implemented and unit-tested, but not yet run against the real service. Please report errors on GitHub to help us improve support for this forge."
                    )
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 280, alignment: .leading)
            }
        }
    }
}

extension Maturity {
    /// Plain-text suffix for menu pickers, which can't draw a badge.
    var pickerSuffix: String {
        isUntested
            ? String(
                localized: " (untested)", bundle: .l10n,
                comment:
                    "Suffix appended to a forge/runtime name in a menu picker when it hasn't been tested against the real service"
            )
            : ""
    }
}
