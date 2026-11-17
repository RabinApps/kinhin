import KinhinKit
import SwiftUI

/// The Support kinhin sheet, opened from the sidebar star and the Settings Support card: one row per donation channel
/// (GitHub Sponsors, PayPal, Buy Me a Coffee), all sourced from `SupportLinks`.
struct SponsorSheet: View {
    let close: () -> Void

    var body: some View {
        SheetScaffold(
            title: "Support kinhin", width: 380,
            content: {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HintText("kinhin is free and built by one developer. Donations and sponsors keep it going.")
                    VStack(spacing: Spacing.sm) {
                        channelRow(
                            icon: "chevron.left.forwardslash.chevron.right", channel: SupportLinks.githubSponsors)
                        channelRow(icon: "creditcard.fill", channel: SupportLinks.payPal)
                        channelRow(icon: "cup.and.saucer.fill", channel: SupportLinks.buyMeACoffee)
                    }
                    HStack(spacing: Spacing.xs) {
                        HintText("Want your logo here?")
                        Link("Become a sponsor", destination: SupportLinks.becomeASponsor.url)
                            .typeStyle(.caption)
                            .fontWeight(.medium)
                    }
                }
            },
            footer: { SheetDoneFooter(done: close) })
    }

    /// One tappable donation channel: its icon, the channel's name and blurb, and an opens-in-browser affordance.
    private func channelRow(icon: String, channel: SupportLinks.Channel) -> some View {
        Link(destination: channel.url) {
            InsetRow(
                leading: {
                    Image(systemName: icon)
                        .foregroundStyle(Palette.accentText)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                },
                content: {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(verbatim: channel.name).typeStyle(.body).fontWeight(.medium).foregroundStyle(.primary)
                        HintText(verbatim: channel.blurb)
                    }
                },
                trailing: {
                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                })
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Support kinhin with \(channel.name)")
    }
}

#Preview("Sponsor sheet") {
    SponsorSheet(close: {})
}
