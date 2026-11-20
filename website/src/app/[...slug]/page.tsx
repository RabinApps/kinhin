import type { Metadata } from 'next'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { siteURL } from '../../../site.config.ts'
import { MobileDocsToggle } from '../../components/MobileDocsToggle'
import { Sidebar } from '../../components/Sidebar'
import { PageActions } from '../../components/PageActions'
import { Toc } from '../../components/Toc'
import { getManifest, getPage, sidebarContext, sidebarLinksInBuild } from '../../lib/content'
import { JsonLd } from '../../components/JsonLd'
import { renderHast } from '../../lib/hast'
import { DOCS_VERSION, articleLd, breadcrumbs, canonical, metaDescription, metaTitle, ogImage, pageTitle } from '../../lib/seo'

export const dynamicParams = false

export function generateStaticParams() {
  return getManifest().pages.filter((p) => p.route !== '').map((p) => ({ slug: p.route.split('/') }))
}

type Props = { params: Promise<{ slug: string[] }> }

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const route = (await params).slug.join('/')
  const page = getPage(route)
  if (!page) return {}
  const title = metaTitle(pageTitle(page.meta))
  const description = metaDescription(page.meta.description)
  const post = route.startsWith('blog/') && route !== 'blog'
  return {
    title,
    description,
    // A release snapshot is old documentation for an old version: keep it out of the index and point at the latest page.
    ...(DOCS_VERSION ? { robots: { index: false, follow: true } } : {}), // an explicit `robots: undefined` would erase the layout's
    alternates: { canonical: canonical(route), types: { 'text/markdown': `/${route}.md`, 'application/atom+xml': '/blog/feed.xml' } },
    openGraph: {
      type: post ? 'article' : 'website',
      siteName: 'kinhin',
      locale: 'en_US',
      title,
      description,
      url: canonical(route),
      images: [ogImage],
      ...(post && page.meta.date ? { publishedTime: page.meta.date } : {}),
    },
    twitter: { card: 'summary_large_image', title, description, images: [ogImage.url] },
  }
}

export default async function Page({ params }: Props) {
  const route = (await params).slug.join('/')
  const page = getPage(route)
  if (!page) notFound()
  const { meta, tree } = page
  const ctx = sidebarContext(route)
  const docs = route.startsWith('guide/') || route.startsWith('cli/')
  const kicker = [route.split('/')[0].toUpperCase(), ctx.group?.toUpperCase()].filter(Boolean).join(' / ')
  return (
    <div className={docs ? 'docs-shell' : 'plain-shell'}>
      {docs && <MobileDocsToggle title={meta.title} />}
      {docs && <Sidebar available={DOCS_VERSION ? sidebarLinksInBuild() : undefined} />}
      <JsonLd data={[articleLd(meta, pageTitle(meta), metaDescription(meta.description)), breadcrumbs(meta, pageTitle(meta))]} />
      <article className="article">
        <nav className="kicker" aria-label="Breadcrumb">
          {docs ? (
            <>
              <Link href={route.startsWith('cli/') ? '/cli/commands' : '/guide/quick-start'}>{route.split('/')[0].toUpperCase()}</Link>
              {ctx.group ? ` / ${ctx.group.toUpperCase()}` : ''}
            </>
          ) : route.startsWith('blog') ? (
            <Link href="/blog">{'// BLOG'}</Link>
          ) : (
            '// GUIDE'
          )}
        </nav>
        <h1>{meta.title}</h1>
        <PageActions route={route} src={meta.src} />
        <div className="prose">{renderHast(tree)}</div>
        {docs && (ctx.prev || ctx.next) && (
          <nav className="pager" aria-label="Previous and next page">
            {ctx.prev ? <Link href={ctx.prev.link}><small>← Previous</small><span>{ctx.prev.text}</span></Link> : <span />}
            {ctx.next ? <Link href={ctx.next.link} className="next"><small>Next →</small><span>{ctx.next.text}</span></Link> : <span />}
          </nav>
        )}
      </article>
      {docs && <Toc headings={meta.headings} />}
    </div>
  )
}
