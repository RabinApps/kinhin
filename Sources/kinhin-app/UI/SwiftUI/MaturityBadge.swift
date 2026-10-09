import KinhinKit
import SwiftUI

/// A small "untested" tag for a forge or runtime that has not been run against
/// the real service (see `MaturityTable`). Draws nothing for a live-tested one.
struct MaturityBadge: View {
    let maturity: Maturity

    init(_ maturity: Maturity) { self.maturity = maturity }
    init(forge: ForgeID) { self.maturity = MaturityTable.maturity(of: forge) }
    init(runtime: RuntimeID) { self.maturity = MaturityTable.maturity(of: runtime) }

    var body: some View {
        if maturity.isUntested {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(StatusStyle.warn.color)
                .help("Implemented and unit-tested, but not yet run against the real service. Please report errors to on GitHub to help us improve support for this forge.")
                .accessibilityLabel("untested")
        }
    }
}

extension Maturity {
    /// Plain-text suffix for menu pickers, which can't draw a badge.
    var pickerSuffix: String { isUntested ? " (untested)" : "" }
}
