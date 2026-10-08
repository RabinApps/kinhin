import KinhinKit
import SwiftUI

/// Fixed per-pool colors so a runtime is the same color everywhere in the
/// Budget card: the allocation bar's segment, the dot on its slider row,
/// and the accessibility summary built on top of them.
enum RuntimeTint {
    static func color(for runtime: RuntimeID) -> Color {
        switch runtime {
        case .tart: return .green
        case .appleContainer: return .blue
        case .docker: return .cyan
        case .host: return .purple
        }
    }
}
