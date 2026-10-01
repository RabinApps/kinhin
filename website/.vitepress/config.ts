import { defineConfig } from 'vitepress'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { docsLinks } from './docsLinks'

// https://vitepress.dev/reference/site-config
const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const docsDir = path.resolve(siteRoot, '..', 'docs') + path.sep

export default defineConfig({
  title: 'Kinhin',
  description:
    'The mindful CI — autoscaling CI runners that live on your Mac. ' +
    'macOS jobs on Tart VMs, Linux jobs on apple/container microVMs or Docker.',
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: '/enso.svg' }]],

  // docs/ is the single source for the guides: the site reads the repo root and publishes only
  // the pages listed here, so nothing under website/guide is a copy of a docs/ page.
  // Site-only pages (quick-start, config, troubleshooting, CLI) stay under website/.
  srcDir: '..',
  srcExclude: [
    '*.md',
    '{Sources,Tests,Plugins,scripts,dist,shots}/**',
    '**/node_modules/**',
    'docs/plans/**',
    'docs/{app,architecture}.md',
  ],
  rewrites: {
    'website/index.md': 'index.md',
    'website/guide/:page.md': 'guide/:page.md',
    'website/cli/:page.md': 'cli/:page.md',
    'docs/why.md': 'guide/why-kinhin.md',
    'docs/forges/README.md': 'guide/forges/index.md',
    'docs/forges/:page.md': 'guide/forges/:page.md',
    'docs/:page.md': 'guide/:page.md',
  },
  markdown: { config: (md) => md.use(docsLinks) },
  vite: {
    plugins: [
      {
        // docs/ pages sit outside website/, so Node resolution never reaches website/node_modules:
        // resolve their bare imports (vue, vitepress) as if the page lived in the site.
        name: 'kinhin-resolve-from-site',
        enforce: 'pre',
        async resolveId(source, importer, options) {
          if (!importer || !importer.split('?')[0].startsWith(docsDir)) return null
          if (/^([./]|\0|[a-z]+:)/i.test(source)) return null
          return this.resolve(source, path.join(siteRoot, 'index.md'), { ...options, skipSelf: true })
        },
      },
    ],
  },

  themeConfig: {
    siteTitle: 'kinhin ○',
    nav: [
      { text: 'Guide', link: '/guide/quick-start' },
      { text: 'CLI', link: '/cli/commands' },
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Why kinhin', link: '/guide/why-kinhin' },
          { text: 'Quick start', link: '/guide/quick-start' },
          { text: 'Install & updates', link: '/guide/install' },
          { text: 'Configuration', link: '/guide/config' },
          { text: 'Toolchains & shared cache', link: '/guide/toolchains' },
          { text: 'How scaling works', link: '/guide/scaling' },
          { text: 'Runtimes & routing', link: '/guide/runtimes' },
          { text: 'Forge support', link: '/guide/forges' },
          { text: 'Security', link: '/guide/security' },
          { text: 'Troubleshooting', link: '/guide/troubleshooting' },
          { text: 'Debugging races (TSan)', link: '/guide/debugging-races' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'CLI commands', link: '/cli/commands' },
          { text: 'Forge API reference', link: '/guide/forges/' },
          { text: 'GitHub API', link: '/guide/forges/github' },
          { text: 'Gitea & Forgejo API', link: '/guide/forges/gitea' },
          { text: 'GitLab API', link: '/guide/forges/gitlab' },
          { text: 'Buildkite API', link: '/guide/forges/buildkite' },
          { text: 'Azure DevOps API', link: '/guide/forges/azuredevops' },
          { text: 'Bitbucket API', link: '/guide/forges/bitbucket' },
        ],
      },
    ],
    socialLinks: [{ icon: 'github', link: 'https://github.com/RabinApps/kinhin' }],
    search: { provider: 'local' },
    outline: { level: [2, 3] },
    footer: {
      message: 'Released under the Apache License 2.0.',
      copyright: 'Copyright © 2026 Rabin Apps, LLC',
    },
  },
})
