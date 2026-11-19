/**
 * Site-wide configuration: navigation, the docs sidebar and footer text. Imported by both the Next.js app
 * and the content pipeline (scripts/content), so it stays plain TypeScript with no framework imports.
 * Adding a page to the docs: put the markdown under docs/ and add one line to `sidebar` below
 * (docs/adding-a-forge.md has the full checklist for a forge).
 */
export interface SidebarItem {
  text: string
  link?: string
  /** Start collapsed; opens when it holds the current page. */
  collapsed?: boolean
  items?: SidebarItem[]
}

export const siteURL = 'https://kinhin.dev'
export const repoURL = 'https://github.com/RabinApps/kinhin'
export const siteTitle = 'kinhin'
export const siteDescription =
  'Your Mac is your CI and your repo is your video studio. Autoscaling ephemeral runners for GitHub, GitLab, ' +
  'Gitea and Forgejo, plus narrated launch videos built from a config.'

export const nav = [
  { text: 'Guide', link: '/guide/quick-start' },
  { text: 'Blog', link: '/blog' },
  { text: 'Docs', link: '/guide/why-kinhin' },
]

export const sidebar: SidebarItem[] = [
  {
    text: 'Get started',
    items: [
      { text: 'Why kinhin', link: '/guide/why-kinhin' },
      { text: 'Compare to other CI', link: '/guide/compare' },
      { text: 'Quick start', link: '/guide/quick-start' },
      { text: 'Install & updates', link: '/guide/install' },
      { text: 'Forge support', link: '/guide/forges' },
      { text: 'Configuration', link: '/guide/config' },
    ],
  },
  {
    text: 'Run your fleet',
    items: [
      { text: 'Runtimes & routing', link: '/guide/runtimes' },
      { text: 'How scaling works', link: '/guide/scaling' },
      { text: 'Toolchains & shared cache', link: '/guide/toolchains' },
      { text: 'Requeue and skip queued jobs', link: '/guide/requeue-skip' },
      { text: 'The healing agent', link: '/guide/healing' },
      { text: 'Telemetry (OpenTelemetry)', link: '/guide/telemetry' },
      { text: 'Alerts (webhooks)', link: '/guide/alerts' },
      { text: 'Test workflows locally', link: '/guide/workflow-testing' },
      { text: 'Benchmarks', link: '/guide/benchmarks' },
    ],
  },
  {
    text: 'Mobile releases',
    items: [
      { text: 'Tutorial: first build', link: '/guide/mobile-fastlane-tutorial' },
      { text: 'Reference', link: '/guide/mobile-fastlane' },
      { text: 'Credentials', link: '/guide/mobile-credentials' },
      { text: 'Store screenshots', link: '/guide/mobile-screenshots' },
      { text: 'Troubleshooting', link: '/guide/mobile-fastlane-troubleshooting' },
    ],
  },
  {
    text: 'Hardware & hosting',
    items: [
      { text: 'Hardware & sizing', link: '/guide/hardware' },
      { text: 'Running on a rented Mac', link: '/guide/rented-mac' },
    ],
  },
  {
    text: 'Security',
    items: [
      { text: 'Security', link: '/guide/security' },
      { text: 'Open-source projects', link: '/guide/open-source' },
    ],
  },
  {
    text: 'Product videos',
    collapsed: true,
    items: [
      { text: 'Add videos to your project', link: '/guide/videos-for-your-project' },
      { text: 'Video config reference', link: '/guide/video-config' },
      { text: 'Recordings of your product', link: '/guide/video-adapters' },
      { text: 'Video troubleshooting', link: '/guide/video-troubleshooting' },
      { text: 'Video gallery', link: '/guide/video-gallery' },
      { text: 'Marketing video in CI', link: '/guide/ci-video' },
    ],
  },
  {
    text: 'Help',
    items: [
      { text: 'Troubleshooting', link: '/guide/troubleshooting' },
      { text: 'Beta roadmap', link: '/guide/beta-roadmap' },
      { text: 'Support & sponsors', link: '/guide/support' },
      { text: 'Who uses kinhin', link: '/guide/used-by' },
    ],
  },
  {
    text: 'Reference',
    items: [
      { text: 'CLI commands', link: '/cli/commands' },
      { text: 'AI agents & MCP', link: '/guide/agents' },
      { text: 'Architecture', link: '/guide/architecture' },
      {
        text: 'Forge API notes',
        collapsed: true,
        items: [
          { text: 'Overview', link: '/guide/forges/overview' },
          { text: 'GitHub', link: '/guide/forges/github' },
          { text: 'Gitea & Forgejo', link: '/guide/forges/gitea' },
          { text: 'GitLab', link: '/guide/forges/gitlab' },
          { text: 'Buildkite (planned)', link: '/guide/forges/buildkite' },
          { text: 'Azure DevOps (experimental)', link: '/guide/forges/azuredevops' },
          { text: 'Bitbucket (planned)', link: '/guide/forges/bitbucket' },
        ],
      },
    ],
  },
  {
    text: 'Contributing',
    collapsed: true,
    items: [
      { text: 'Contributing', link: '/guide/contributing' },
      { text: 'End-to-end testing', link: '/guide/e2e-testing' },
      { text: 'Setting up the hosted e2e lanes', link: '/guide/e2e-hosted-forges' },
      { text: "Making kinhin's demo video", link: '/guide/making-a-video' },
      { text: 'Debugging races (TSan)', link: '/guide/debugging-races' },
      { text: 'Cutting a release', link: '/guide/releasing' },
    ],
  },
]

export const footer = {
  license: 'Released under the Apache License 2.0.',
  copyright: 'Copyright © 2026 Rabin Apps, LLC',
  links: [
    { text: 'Support kinhin', href: '/guide/support' },
    { text: 'Who uses kinhin', href: '/guide/used-by' },
    { text: 'SupDesk', href: 'https://supdesk.app/en' },
  ],
}

/** Flat list of sidebar links in reading order (for prev/next and llms.txt). */
export function flattenSidebar(items: SidebarItem[] = sidebar): { text: string; link: string }[] {
  return items.flatMap((i) => [...(i.link ? [{ text: i.text, link: i.link }] : []), ...flattenSidebar(i.items ?? [])])
}

/** Closing block on every search-intent page (also emitted into the markdown copies). */
export const searchNextSteps = [
  { text: 'Quick start', href: '/guide/quick-start', note: 'From zero to a working fleet' },
  { text: 'Install', href: '/guide/install', note: 'Pinned versions, updates and uninstall' },
  { text: 'Forge support', href: '/guide/forges', note: 'What has been run against a real server' },
  { text: 'Why kinhin', href: '/guide/why-kinhin', note: 'Why most runners do one job at a time' },
]
