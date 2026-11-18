import type { NextConfig } from 'next'

// Unset = the latest docs, served at "/" by the Cloudflare Worker (OpenNext). A release snapshot is the same
// app built from an old tag's markdown with DOCS_VERSION=<tag>: a static export under "/<tag>/", copied
// into the Worker's static assets (see .github/workflows/docs.yml).
const version = process.env.DOCS_VERSION || ''

const config: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  images: { unoptimized: true },
  env: { NEXT_PUBLIC_BASE_PATH: version ? `/${version}` : '', NEXT_PUBLIC_DOCS_VERSION: version },
  ...(version
    ? { output: 'export' as const, basePath: `/${version}`, trailingSlash: false, distDir: `.snapshots/${version}` }
    : {
        // The old VitePress site served `/page.html`, `/section/` (an index page) and `/guide/forges/` (the forge overview,
        // now /guide/forges/overview because /guide/forges is its own page). Search engines and ~200 links in the wild
        // use those URLs, so each answers with a permanent redirect to its new home. Trailing slashes are handled here,
        // not by Next, so the forge overview keeps its old address.
        skipTrailingSlashRedirect: true,
        async redirects() {
          return [
            { source: '/index.html', destination: '/', permanent: true },
            { source: '/guide/forges/', destination: '/guide/forges/overview', permanent: true },
            { source: '/guide/forges/index.html', destination: '/guide/forges/overview', permanent: true },
            { source: '/:path*/index.html', destination: '/:path*', permanent: true },
            { source: '/:path*.html', destination: '/:path*', permanent: true },
            { source: '/:path+/', destination: '/:path+', permanent: true },
          ]
        },
        async rewrites() {
          return [
            { source: '/index.md', destination: '/md/index' },
            { source: '/:path*.md', destination: '/md/:path*' },
          ]
        },
      }),
}

export default config
