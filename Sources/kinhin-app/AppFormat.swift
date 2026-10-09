import Foundation

/// Locale-aware number, duration and size formatting for app UI. Always go through these (or a
/// `Formatter` / `FormatStyle` directly) instead of building "5s", "3 GB" or "2 minutes ago" by hand.
enum AppFormat {
    /// A short elapsed time ("45s", "1m 6s"), in the user's language.
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds.rounded(.down)) ?? seconds.formatted()
    }

    /// A file or memory size ("1.2 GB") for a byte count.
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// A relative time ("2 minutes ago") for a past date.
    static func relative(_ date: Date, to reference: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
