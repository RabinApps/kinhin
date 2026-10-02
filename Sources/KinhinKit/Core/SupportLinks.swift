import Foundation

/// Where to donate or sponsor kinhin, and who already does. One source for the
/// menu bar app and the CLI; the website mirrors it in `website/.vitepress/sponsors.ts`.
public enum SupportLinks {
    public struct Channel: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let blurb: String
    }

    public struct Sponsor: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let blurb: String
    }

    public struct Project: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let blurb: String
    }

    // The literals below are constants; a malformed one is caught by SupportLinksTests.
    private static func link(_ string: String) -> URL {
        guard let url = URL(string: string) else { preconditionFailure("invalid support URL: \(string)") }
        return url
    }

    public static let githubSponsors = Channel(
        name: "GitHub Sponsors", url: link("https://github.com/sponsors/RabinApps"),
        blurb: "Monthly or one-time sponsorship, with tiers")
    public static let payPal = Channel(
        name: "PayPal", url: link("https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC"),
        blurb: "One-time donation")
    public static let buyMeACoffee = Channel(
        name: "Buy Me a Coffee", url: link("https://buymeacoffee.com/rabinapps"),
        blurb: "One-time or $1/month")
    public static let becomeASponsor = Channel(
        name: "Become a sponsor", url: link("mailto:support@rabinapps.com?subject=kinhin%20sponsorship"),
        blurb: "Put your logo on kinhin: support@rabinapps.com")

    /// Individual donation channels, in display order.
    public static let donate: [Channel] = [githubSponsors, payPal, buyMeACoffee]

    /// Companies that sponsor kinhin. Empty until the first paid sponsor signs up.
    public static let sponsors: [Sponsor] = []

    /// Other Rabin Apps projects.
    public static let projects: [Project] = [
        Project(
            name: "SupDesk", url: link("https://supdesk.app/en"),
            blurb: "Feedback and support console for solo founders, devs and small teams")
    ]

    /// Text for `kinhin support`.
    public static func summary() -> String {
        var lines = ["Support kinhin", ""]
        for channel in donate {
            lines.append(
                "  \(channel.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(channel.url.absoluteString)")
        }
        lines.append("")
        lines.append("Sponsor with your logo: support@rabinapps.com")
        if !sponsors.isEmpty {
            lines.append("")
            lines.append("Sponsored by")
            for sponsor in sponsors {
                lines.append("  \(sponsor.name): \(sponsor.url.absoluteString)")
            }
        }
        lines.append("")
        lines.append("More from Rabin Apps")
        for project in projects {
            lines.append("  \(project.name): \(project.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }
}
