// The website's single source of truth for who sponsors kinhin and which
// projects use it.

export interface Sponsor {
  name: string;
  url: string;
  blurb: string;
}

export interface Project {
  name: string;
  url: string;
  blurb: string;
}

export interface Contributor {
  sponsor: Sponsor | null;
  project: Project | null;
}

/**
 * Community submissions come through the used-by.md PR process;
 * maintainers review them before merging, so this list is a curated
 * representation, not raw PR content.
 */
export const contributors: Contributor[] = [
  // Add new entries here when a company or project signs up.
  // Example:
  // { sponsor: { name: "Acme Corp", url: "https://acme.example", blurb: "Runs CI on kinhin" }, project: null },
  // { sponsor: null, project: { name: "MyProject", url: "https://myproject.example", blurb: "Uses kinhin for CI" } },
];

/** Companies that sponsor kinhin. Mirrors `SupportLinks.sponsors`. */
export const sponsors: Sponsor[] = [
  {
    name: "SupDesk",
    url: "https://supdesk.app",
    blurb:
      "Feedback and support console for solo founders, devs and small teams",
  },
];

export const internalSponsors: Sponsor[] = [
  {
    name: "GitHub Sponsors",
    url: "https://github.com/sponsors/RabinApps",
    blurb: "Monthly or one-time sponsorship, with tiers",
  },
  {
    name: "PayPal",
    url: "https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC",
    blurb: "One-time donation",
  },
  {
    name: "Buy Me a Coffee",
    url: "https://buymeacoffee.com/rabinapps",
    blurb: "One-time or $1/month",
  },
];

export const internalProjects: Project[] = [
  {
    name: "SupDesk",
    url: "https://supdesk.app/en",
    blurb:
      "Feedback and support console for solo founders, devs and small teams",
  },
];
