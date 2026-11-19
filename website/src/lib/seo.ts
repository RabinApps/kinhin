import { siteDescription, siteTitle, siteURL, repoURL } from '../../site.config.ts'
import type { PageMeta } from './content'

/** SEO helpers shared by the home page and the doc pages: titles, descriptions, canonical URLs, structured data. */

export const DOCS_VERSION = process.env.NEXT_PUBLIC_DOCS_VERSION ?? ''
/** A release snapshot is canonical to itself (it is noindex, and a page that only exists in an old tag has no latest equivalent). */
export const canonical = (route: string): string => `${siteURL}${DOCS_VERSION ? `/${DOCS_VERSION}` : ''}/${route}`

/** Search results show about 155 to 160 characters: cut at a word boundary and end on an ellipsis. */
export function metaDescription(text: string, max = 160): string {
  const t = text.replace(/\s+/g, ' ').trim()
  if (t.length <= max) return t
  const cut = t.slice(0, max - 1)
  return cut.slice(0, cut.lastIndexOf(' ')).replace(/[\s,;:.\-–—]+$/, '') + '…'
}

/**
 * The text of `<title>` (the visible h1 stays whole): about 60 characters, so a long post title is not cut mid-word in a
 * results page. Cut at a comma or a space, never inside a word.
 */
export function metaTitle(title: string, max = 60): string {
  if (title.length <= max) return title
  const cut = title.slice(0, max - 1)
  const at = Math.max(cut.lastIndexOf(','), cut.lastIndexOf(' '))
  return cut.slice(0, at > 20 ? at : max - 1).replace(/[\s,;:.\-–—]+$/, '') + '…'
}

/** Page titles: the per-forge notes would otherwise be just "GitHub" or "GitLab". */
export function pageTitle(p: PageMeta): string {
  if (/^guide\/forges\/(?!overview$)/.test(p.route)) return `${p.title}: forge API notes`
  return p.title
}

export const ogImage = { url: '/og.png', width: 1200, height: 630, alt: 'kinhin: Your Mac is your CI' }

const section = (route: string): { name: string; path: string } | undefined =>
  route.startsWith('guide/') ? { name: 'Guide', path: '/guide/quick-start' } : route.startsWith('cli/') ? { name: 'CLI', path: '/cli/commands' } : route.startsWith('blog/') ? { name: 'Blog', path: '/blog' } : undefined

const publisher = { '@type': 'Organization', name: 'Rabin Apps, LLC', url: 'https://supdesk.app/en', sameAs: [repoURL, 'https://supdesk.app/en'], logo: { '@type': 'ImageObject', url: `${siteURL}/logo.png` } }

export function breadcrumbs(p: PageMeta, title: string): object {
  const trail = [{ name: 'kinhin', url: `${siteURL}/` }]
  const s = section(p.route)
  if (s && p.route !== 'blog') trail.push({ name: s.name, url: `${siteURL}${s.path}` })
  trail.push({ name: title, url: canonical(p.route) })
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: trail.map((t, i) => ({ '@type': 'ListItem', position: i + 1, name: t.name, item: t.url })),
  }
}

export function articleLd(p: PageMeta, title: string, description: string): object {
  const post = p.route.startsWith('blog/') && p.route !== 'blog'
  return {
    '@context': 'https://schema.org',
    '@type': post ? 'BlogPosting' : 'TechArticle',
    headline: title,
    description,
    url: canonical(p.route),
    mainEntityOfPage: canonical(p.route),
    inLanguage: 'en',
    image: `${siteURL}${ogImage.url}`,
    ...(p.date ? { datePublished: p.date, dateModified: p.date } : {}),
    author: post ? { '@type': 'Person', name: 'Alex Rabin' } : publisher,
    publisher,
    isPartOf: { '@type': 'WebSite', name: siteTitle, url: siteURL },
  }
}

export function homeLd(): object[] {
  return [
    { '@context': 'https://schema.org', '@type': 'WebSite', name: siteTitle, url: siteURL, description: siteDescription, inLanguage: 'en', publisher },
    {
      '@context': 'https://schema.org',
      '@type': 'SoftwareApplication',
      name: 'kinhin',
      description: siteDescription,
      url: siteURL,
      applicationCategory: 'DeveloperApplication',
      operatingSystem: 'macOS 15 or later (Apple Silicon)',
      license: 'https://www.apache.org/licenses/LICENSE-2.0',
      isAccessibleForFree: true,
      offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
      codeRepository: repoURL,
      downloadUrl: `${repoURL}/releases/latest`,
      publisher,
    },
  ]
}
