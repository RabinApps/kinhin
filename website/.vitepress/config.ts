import { defineConfig } from "vitepress";
import fs from "node:fs";
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
// The custom domain GitHub Pages serves (website/public/CNAME). Social cards need absolute URLs.
const siteURL = "https://kinhin.dev";

export default defineConfig({
  base,
  title: "Kinhin",
  description:
    "Your Mac is your CI and your repo is your video studio. Autoscaling ephemeral runners for GitHub, GitLab, " +
    "Gitea and Forgejo, plus narrated launch videos built from a config.",
  sitemap: { hostname: `${siteURL}${base}` },
  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: `${base}favicon.svg` }],
    ["link", { rel: "icon", type: "image/png", sizes: "32x32", href: `${base}favicon-32.png` }],
    ["link", { rel: "apple-touch-icon", href: `${base}apple-touch-icon.png` }],
    ["meta", { property: "og:image", content: `${siteURL}${base}og.png` }],
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
  ],

  // docs/ is the single source for the guides: the site reads the repo root and publishes only
  // the pages listed here, so nothing under website/guide is a copy of a docs/ page.
  // Site-only pages (quick-start, config, troubleshooting, CLI) stay under website/.
  srcDir: "..",
  srcExclude: [
    "*.md",
    "{Sources,Tests,Plugins,scripts,dist,shots,assets,video}/**",
    "**/node_modules/**",
    "docs/plans/**",
    "docs/{app,adding-a-forge}.md",
    "skills/**",
    "examples/**",
  ],
  rewrites: {
    "website/index.md": "index.md",
    "website/guide/:page.md": "guide/:page.md",
    "website/cli/:page.md": "cli/:page.md",
    "website/blog/:page.md": "blog/:page.md",
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
  // srcDir is the repo root, so VitePress would look for static files in <repo>/public. Keep them in
  // website/public instead: Vite serves it in dev, and buildEnd copies it into the output.
  buildEnd: async (siteConfig) => {
    fs.cpSync(path.join(siteRoot, "public"), siteConfig.outDir, { recursive: true });
  },
  vite: {
    publicDir: path.join(siteRoot, "public"),
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
    // The app icon has its own white tile, so it stays visible in dark mode (the bare mark did not).
    logo: { src: "/logo.png", alt: "kinhin" },
    siteTitle: "kinhin",
    nav: [
      { text: "Guide", link: "/guide/quick-start" },
      { text: "CLI", link: "/cli/commands" },
      { text: "Blog", link: "/blog/" },
      {
        text: docsVersion ?? "Latest",
        items: [
          // Full URLs: VitePress prefixes `base` onto "/" links, so inside a snapshot "/" pointed back
          // at the snapshot itself instead of the latest docs.
          { text: "Latest (main)", link: `${siteURL}/`, target: "_self", rel: "" },
          ...versions.map((v: string) => ({
            text: v,
            link: `${siteURL}/${v}/`,
            target: "_self",
            rel: "",
          })),
        ],
      },
    ],
    sidebar: [
      {
        text: "Get started",
        items: [
          { text: "Why kinhin", link: "/guide/why-kinhin" },
          { text: "Compare to other CI", link: "/guide/compare" },
          { text: "Quick start", link: "/guide/quick-start" },
          { text: "Install & updates", link: "/guide/install" },
          { text: "Forge support", link: "/guide/forges" },
          { text: "Configuration", link: "/guide/config" },
        ],
      },
      {
        text: "Run your fleet",
        items: [
          { text: "Runtimes & routing", link: "/guide/runtimes" },
          { text: "How scaling works", link: "/guide/scaling" },
          { text: "Toolchains & shared cache", link: "/guide/toolchains" },
          { text: "Requeue and skip queued jobs", link: "/guide/requeue-skip" },
          { text: "Test workflows locally", link: "/guide/workflow-testing" },
          { text: "Benchmarks", link: "/guide/benchmarks" },
        ],
      },
      {
        text: "Mobile releases",
        collapsed: false,
        items: [
          { text: "Tutorial: first build", link: "/guide/mobile-fastlane-tutorial" },
          { text: "Reference", link: "/guide/mobile-fastlane" },
          { text: "Credentials", link: "/guide/mobile-credentials" },
          { text: "Store screenshots", link: "/guide/mobile-screenshots" },
          { text: "Troubleshooting", link: "/guide/mobile-fastlane-troubleshooting" },
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
        text: "Security",
        items: [
          { text: "Security", link: "/guide/security" },
          { text: "Open-source projects", link: "/guide/open-source" },
        ],
      },
      {
        text: "Product videos",
        collapsed: true,
        items: [
          { text: "Add videos to your project", link: "/guide/videos-for-your-project" },
          { text: "Video gallery", link: "/guide/video-gallery" },
          { text: "Marketing video in CI", link: "/guide/ci-video" },
        ],
      },
      {
        text: "Help",
        items: [
          { text: "Troubleshooting", link: "/guide/troubleshooting" },
          { text: "Beta roadmap", link: "/guide/beta-roadmap" },
          { text: "Support & sponsors", link: "/guide/support" },
          { text: "Who uses kinhin", link: "/guide/used-by" },
        ],
      },
      {
        text: "Reference",
        items: [
          { text: "CLI commands", link: "/cli/commands" },
          { text: "AI agents & MCP", link: "/guide/agents" },
          { text: "Architecture", link: "/guide/architecture" },
          {
            text: "Forge API notes",
            collapsed: true,
            items: [
              { text: "Overview", link: "/guide/forges/" },
              { text: "GitHub", link: "/guide/forges/github" },
              { text: "Gitea & Forgejo", link: "/guide/forges/gitea" },
              { text: "GitLab", link: "/guide/forges/gitlab" },
              { text: "Buildkite (planned)", link: "/guide/forges/buildkite" },
              { text: "Azure DevOps (planned)", link: "/guide/forges/azuredevops" },
              { text: "Bitbucket (planned)", link: "/guide/forges/bitbucket" },
            ],
          },
        ],
      },
      {
        text: "Contributing",
        collapsed: true,
        items: [
          { text: "Contributing", link: "/guide/contributing" },
          { text: "End-to-end testing", link: "/guide/e2e-testing" },
          { text: "Making kinhin's demo video", link: "/guide/making-a-video" },
          { text: "Debugging races (TSan)", link: "/guide/debugging-races" },
          { text: "Cutting a release", link: "/guide/releasing" },
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
