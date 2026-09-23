import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: 'Kinhin',
  description:
    'The mindful CI — autoscaling CI runners that live on your Mac. ' +
    'macOS jobs on Tart VMs, Linux jobs on apple/container microVMs or Docker.',
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: '/enso.svg' }]],

  themeConfig: {
    siteTitle: 'kinhin ○',
    nav: [
      { text: 'Guide', link: '/guide/quick-start' },
      { text: 'CLI', link: '/cli/commands' },
      { text: 'Migrating', link: '/guide/migrating' },
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Quick start', link: '/guide/quick-start' },
          { text: 'Configuration', link: '/guide/config' },
          { text: 'Toolchains & shared cache', link: '/guide/toolchains' },
          { text: 'Runtimes & routing', link: '/guide/runtimes' },
          { text: 'Forge support', link: '/guide/forges' },
          { text: 'Migrating from Orchard', link: '/guide/migrating' },
          { text: 'Troubleshooting', link: '/guide/troubleshooting' },
        ],
      },
      {
        text: 'Reference',
        items: [{ text: 'CLI commands', link: '/cli/commands' }],
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
