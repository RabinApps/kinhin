import type { Metadata } from 'next'
import { siteDescription } from '../../site.config.ts'
import { Home } from '../components/Home'
import { JsonLd } from '../components/JsonLd'
import { getManifest } from '../lib/content'
import { DOCS_VERSION, canonical, homeLd, metaDescription, ogImage } from '../lib/seo'

const title = 'kinhin: Your Mac is your CI'
const description = metaDescription(siteDescription, 200)

export const metadata: Metadata = {
  title: { absolute: title },
  description,
  ...(DOCS_VERSION ? { robots: { index: false, follow: true } } : {}), // an explicit `robots: undefined` would erase the layout's
  alternates: { canonical: canonical(''), types: { 'text/markdown': '/index.md', 'application/atom+xml': '/blog/feed.xml' } },
  openGraph: { type: 'website', siteName: 'kinhin', locale: 'en_US', title, description, url: canonical(''), images: [ogImage] },
  twitter: { card: 'summary_large_image', title, description, images: [ogImage.url] },
}

export default function Page() {
  return (
    <>
      <JsonLd data={homeLd()} />
      <Home data={getManifest().home} />
    </>
  )
}
