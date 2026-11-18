import type { MetadataRoute } from 'next'
import { siteURL } from '../../site.config.ts'
import { getManifest } from '../lib/content'

export const dynamic = 'force-static'

export default function sitemap(): MetadataRoute.Sitemap {
  // Like the VitePress sitemap it replaces: one <loc> per published page, nothing else (no lastmod, changefreq or priority).
  return getManifest().pages.map((p) => ({ url: `${siteURL}/${p.route}` }))
}
