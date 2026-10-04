import KinhinKit
import SwiftUI

/// The sponsor sheet, opened from the star button in the window's top-right
/// corner: one row per donation channel (GitHub Sponsors, PayPal, Buy Me a
/// Coffee), all sourced from `SupportLinks`.
struct SponsorSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("Support kinhin").font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            Text("kinhin is free and built by one developer. Donations and sponsors keep it going.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                channelRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    tint: Color(nsColor: .labelColor),
                    iconColor: Color(nsColor: .windowBackgroundColor),
                    channel: SupportLinks.githubSponsors)
                channelRow(
                    icon: "creditcard.fill",
                    tint: Color(red: 0.0, green: 0.47, blue: 0.84),
                    iconColor: .white,
                    channel: SupportLinks.payPal)
                channelRow(
                    icon: "cup.and.saucer.fill",
                    tint: Color(red: 1.0, green: 0.78, blue: 0.16),
                    iconColor: .black,
                    channel: SupportLinks.buyMeACoffee)
            }

            Divider()
            HStack(spacing: 4) {
                HintText("Want your logo here?")
                Link("Become a sponsor", destination: SupportLinks.becomeASponsor.url)
                    .font(.system(size: 11))
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .leading)
    }

    /// One tappable donation channel: the icon in a tinted square, the
    /// channel's name and blurb, and an opens-in-browser affordance.
    private func channelRow(
        icon: String,
        tint: Color,
        iconColor: Color,
        channel: SupportLinks.Channel
    ) -> some View {
        Link(destination: channel.url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(channel.blurb)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Support kinhin with \(channel.name)")
    }
}
