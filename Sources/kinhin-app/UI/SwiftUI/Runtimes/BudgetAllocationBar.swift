import KinhinKit
import SwiftUI

/// The Budget card's whole-split bar: one colored segment per pool, sized
/// by its share of the total, with the percentage inside when it fits.
/// Pools at a zero share simply aren't on the bar — their row says so.
struct BudgetAllocationBar: View {
    let rows: [RuntimesModel.BudgetRow]

    /// Below this share a segment can't fit a readable "%" label.
    private static let labelThreshold = 0.12
    /// Gap between segments, in points.
    private static let spacing: CGFloat = 2

    /// One bar segment: the pool and its slice of the total.
    struct Segment: Identifiable {
        let id: RuntimeID
        let share: Double
    }

    var body: some View {
        let segments = visibleSegments
        GeometryReader { geo in
            let gapTotal = Self.spacing * CGFloat(max(segments.count - 1, 0))
            let barWidth = max(0, geo.size.width - gapTotal)
            HStack(spacing: Self.spacing) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(RuntimeTint.color(for: segment.id))
                        .frame(width: barWidth * segment.share)
                        .overlay {
                            if segment.share >= Self.labelThreshold {
                                Text(percentText(segment.share))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityLabel(summary)
    }

    // MARK: - Segments

    /// Shares scaled to fill the bar even if a hand-edited config names a
    /// runtime the fleet no longer has (its slice would otherwise vanish).
    private var visibleSegments: [Segment] {
        let positive = rows.filter { $0.share > 0 }
        let total = positive.reduce(0.0) { $0 + $1.share }
        guard total > 0 else { return [] }
        return positive.map { Segment(id: $0.id, share: $0.share / total) }
    }

    private func percentText(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    private var summary: String {
        let parts = visibleSegments.map { "\($0.id.rawValue) \(percentText($0.share))" }
        return parts.isEmpty ? "No capacity split yet" : "Capacity split: \(parts.joined(separator: ", "))"
    }
}
