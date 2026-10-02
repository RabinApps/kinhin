import { defineConfig } from "vitepress";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { docsLinks } from "./docsLinks";
import versions from "../versions.json";

// https://vitepress.dev/reference/site-config
const siteRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const docsDir = path.resolve(siteRoot, "..", "docs") + path.sep;

// Unset = the latest docs built from main, served at "/". A release snapshot is built from its tag
// with DOCS_VERSION=<tag> and served under "/<tag>/" (see .github/workflows/docs.yml).
const docsVersion = process.env.DOCS_VERSION;
// A snapshot is beta when its tag has a prerelease suffix. The latest docs (main) are beta until a
// stable release is listed in versions.json.
const isPrerelease = (v: string) => /-(alpha|beta|rc)/i.test(v);
const isBeta = docsVersion
  ? isPrerelease(docsVersion)
  : !(versions as string[]).some((v) => !isPrerelease(v));
const base = docsVersion ? `/${docsVersion}/` : "/";

export default defineConfig({
  base,
  title: "Kinhin",
  description:
    "The mindful CI — autoscaling CI runners that live on your Mac. " +
    "macOS jobs on Tart VMs, Linux jobs on apple/container microVMs or Docker.",
  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: `${base}enso.svg` }],
  ],

  // docs/ is the single source for the guides: the site reads the repo root and publishes only
  // the pages listed here, so nothing under website/guide is a copy of a docs/ page.
  // Site-only pages (quick-start, config, troubleshooting, CLI) stay under website/.
  srcDir: "..",
  srcExclude: [
    "*.md",
    "{Sources,Tests,Plugins,scripts,dist,shots}/**",
    "**/node_modules/**",
    "docs/plans/**",
    "docs/{app,architecture}.md",
  ],
  rewrites: {
    "website/index.md": "index.md",
    "website/guide/:page.md": "guide/:page.md",
    "website/cli/:page.md": "cli/:page.md",
    "docs/why.md": "guide/why-kinhin.md",
    "docs/forges/README.md": "guide/forges/index.md",
    "docs/forges/:page.md": "guide/forges/:page.md",
    "docs/:page.md": "guide/:page.md",
  },
  markdown: { config: (md) => md.use(docsLinks) },
  vite: {
    // Read by the theme to show an "old version" banner on snapshot builds.
    define: {
      __DOCS_VERSION__: JSON.stringify(docsVersion ?? ""),
      __DOCS_BETA__: JSON.stringify(isBeta),
    },
    plugins: [
      {
        // docs/ pages sit outside website/, so Node resolution never reaches website/node_modules:
        // resolve their bare imports (vue, vitepress) as if the page lived in the site.
        name: "kinhin-resolve-from-site",
        enforce: "pre",
        async resolveId(source, importer, options) {
          if (!importer || !importer.split("?")[0].startsWith(docsDir))
            return null;
          if (/^([./]|\0|[a-z]+:)/i.test(source)) return null;
          return this.resolve(source, path.join(siteRoot, "index.md"), {
            ...options,
            skipSelf: true,
          });
        },
      },
    ],
  },

  themeConfig: {
    siteTitle: "kinhin ○",
    nav: [
      { text: "Guide", link: "/guide/quick-start" },
      { text: "CLI", link: "/cli/commands" },
      {
        text: docsVersion ?? "Latest",
        items: [
          // Absolute links bypass `base`, so the picker works from inside any version.
          { text: "Latest (main)", link: "/", target: "_self" },
          ...versions.map((v: string) => ({
            text: v,
            link: `/${v}/`,
            target: "_self",
          })),
        ],
      },
    ],
    sidebar: [
      {
        text: "Guide",
        collapsed: false,
        items: [
          { text: "Why kinhin", link: "/guide/why-kinhin" },
          { text: "Quick start", link: "/guide/quick-start" },
          { text: "Beta roadmap", link: "/guide/beta-roadmap" },
          { text: "Install & updates", link: "/guide/install" },
          { text: "Configuration", link: "/guide/config" },
          { text: "Toolchains & shared cache", link: "/guide/toolchains" },
          { text: "Hardware requirements & sizing", link: "/guide/hardware" },
          { text: "Running on a rented Mac", link: "/guide/rented-mac" },
          { text: "How scaling works", link: "/guide/scaling" },
          { text: "Runtimes & routing", link: "/guide/runtimes" },
          { text: "Forge support", link: "/guide/forges" },
          { text: "Security", link: "/guide/security" },
          { text: "Support & sponsors", link: "/guide/support" },
          {
            text: "Companies & projects using kinhin",
            link: "/guide/external-contributors",
          },
          { text: "Troubleshooting", link: "/guide/troubleshooting" },
          { text: "Debugging races (TSan)", link: "/guide/debugging-races" },
        ],
      },
      {
        text: "Reference",
        collapsed: false,
        items: [
          { text: "CLI commands", link: "/cli/commands" },
          { text: "Forge API reference", link: "/guide/forges/" },
          { text: "GitHub API", link: "/guide/forges/github" },
          {
            text: "Contributing to kinhin",
            link: "/guide/external-contributors",
          },
          { text: "Gitea & Forgejo API", link: "/guide/forges/gitea" },
          { text: "GitLab API", link: "/guide/forges/gitlab" },
          { text: "Buildkite API", link: "/guide/forges/buildkite" },
          { text: "Azure DevOps API", link: "/guide/forges/azuredevops" },
          { text: "Bitbucket API", link: "/guide/forges/bitbucket" },
        ],
      },
    ],
    socialLinks: [
      { icon: "github", link: "https://github.com/RabinApps/kinhin" },
    ],
    search: { provider: "local" },
    outline: { level: [2, 3] },
    footer: {
      message:
        'Released under the Apache License 2.0. <a href="/guide/support">Support kinhin</a> · <a href="/guide/contributing">Companies & projects using kinhin</a> · More from Rabin Apps: <a href="https://supdesk.app/en">SupDesk</a>',
      copyright: "Copyright © 2026 Rabin Apps, LLC",
    },
  },
});
