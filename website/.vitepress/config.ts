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
    "docs/{app,adding-a-forge}.md",
    "skills/**",
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
  markdown: {
    config: (md) => {
      md.use(docsLinks);
      const defaultFence = md.renderer.rules.fence!;
      md.renderer.rules.fence = (tokens, idx, options, env, self) => {
        const token = tokens[idx];
        if (token.info.trim() === "mermaid") {
          return `<pre class="mermaid">${md.utils.escapeHtml(token.content)}</pre>`;
        }
        return defaultFence(tokens, idx, options, env, self);
      };
    },
  },
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
        text: "Get started",
        items: [
          { text: "Why kinhin", link: "/guide/why-kinhin" },
          { text: "Quick start", link: "/guide/quick-start" },
          { text: "Install & updates", link: "/guide/install" },
          { text: "Configuration", link: "/guide/config" },
        ],
      },
      {
        text: "Run your fleet",
        items: [
          { text: "Architecture", link: "/guide/architecture" },
          { text: "Runtimes & routing", link: "/guide/runtimes" },
          { text: "Toolchains & shared cache", link: "/guide/toolchains" },
          { text: "Forge support", link: "/guide/forges" },
          { text: "Test workflows locally", link: "/guide/workflow-testing" },
          { text: "How scaling works", link: "/guide/scaling" },
          { text: "Requeue and skip queued jobs", link: "/guide/requeue-skip" },
        ],
      },
      {
        text: "Hardware & hosting",
        items: [
          { text: "Hardware & sizing", link: "/guide/hardware" },
          { text: "Running on a rented Mac", link: "/guide/rented-mac" },
        ],
      },
      {
        text: "Security & help",
        items: [
          { text: "Security", link: "/guide/security" },
          { text: "Troubleshooting", link: "/guide/troubleshooting" },
          { text: "Beta roadmap", link: "/guide/beta-roadmap" },
        ],
      },
      {
        text: "Community",
        items: [
          { text: "Support & sponsors", link: "/guide/support" },
          { text: "Who uses kinhin", link: "/guide/used-by" },
          { text: "Contributing", link: "/guide/contributing" },
          { text: "Debugging races (TSan)", link: "/guide/debugging-races" },
        ],
      },
      {
        text: "Reference",
        items: [
          { text: "CLI commands", link: "/cli/commands" },
          {
            text: "Forge API notes",
            collapsed: true,
            items: [
              { text: "Overview", link: "/guide/forges/" },
              { text: "GitHub", link: "/guide/forges/github" },
              { text: "Gitea & Forgejo", link: "/guide/forges/gitea" },
              { text: "GitLab", link: "/guide/forges/gitlab" },
              { text: "Buildkite", link: "/guide/forges/buildkite" },
              { text: "Azure DevOps", link: "/guide/forges/azuredevops" },
              { text: "Bitbucket", link: "/guide/forges/bitbucket" },
            ],
          },
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
        'Released under the Apache License 2.0. <a href="/guide/support">Support kinhin</a> · <a href="/guide/used-by">Who uses kinhin</a> · More from Rabin Apps: <a href="https://supdesk.app/en">SupDesk</a>',
      copyright: "Copyright © 2026 Rabin Apps, LLC",
    },
  },
});
