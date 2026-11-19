import { existsSync } from 'node:fs'
import path from 'node:path'
import { codeSpans, outsideFences } from './fences.ts'

/**
 * `docs/` pages are written for GitHub: links are relative to the file and point at the README and at
 * source. Rewriting them while building keeps `docs/` the only copy. (Ported from the VitePress
 * `docsLinks` plugin; unlike it, this works on the markdown text, so the same code serves the HTML
 * pages and the markdown copies.)
 */
export interface LinkContext {
  /** Repo root, or a checkout of an old tag. */
  root: string
  /** Repo-relative source path → route (no leading slash). */
  routes: Map<string, string>
  /** `main`, or the tag when building a release snapshot. */
  ref: string
  /** The latest site's origin; absolute links to it are made relative on the HTML pages. */
  origin: string
}

export const repo = 'https://github.com/RabinApps/kinhin'
export const rawGithub = 'https://raw.githubusercontent.com/RabinApps/kinhin'

const external = /^([a-z][a-z0-9+.-]*:|#|\/\/)/i

export interface ResolvedLink {
  href: string
  /** A relative link in a docs/ page whose target file does not exist (a dead link the build must report). */
  missing: boolean
}

/** Splits a relative link into the repo path to look up and the `?query#anchor` to put back on the result. */
export function splitLink(href: string): { pathname: string; suffix: string } {
  const hashAt = href.indexOf('#')
  const beforeAnchor = hashAt === -1 ? href : href.slice(0, hashAt)
  const anchor = hashAt === -1 ? '' : href.slice(hashAt)
  const queryAt = beforeAnchor.indexOf('?')
  const pathname = queryAt === -1 ? beforeAnchor : beforeAnchor.slice(0, queryAt)
  return { pathname, suffix: (queryAt === -1 ? '' : beforeAnchor.slice(queryAt)) + anchor }
}

/** Decodes each percent-encoded path segment the way a browser would; a malformed escape stays literal instead of throwing. */
function decodePathname(pathname: string): string {
  return pathname
    .split('/')
    .map((segment) => {
      try {
        return decodeURIComponent(segment)
      } catch {
        return segment
      }
    })
    .join('/')
}

/**
 * Resolves a relative link in a docs/ page: site path, GitHub URL, or unchanged. `missing` is true when a relative
 * link points at a file that is not in the checkout — without it the link would be passed through and 404 on the site.
 * Query strings and fragments are not part of the file being looked up, and are preserved on the resolved href.
 */
export function resolveDocsLink(href: string, src: string, ctx: LinkContext): ResolvedLink {
  if (!src.startsWith('docs/') || external.test(href) || href.startsWith('/')) return { href, missing: false }
  const { pathname, suffix } = splitLink(href)
  // A query-only link (`?plain=1#top`) points at this page, not at the directory it lives in.
  if (pathname === '') return { href, missing: false }
  const target = path.posix.normalize(path.posix.join(path.posix.dirname(src), decodePathname(pathname)))
  if (target === 'README.md') return { href: '/' + suffix, missing: false }
  const route = ctx.routes.get(target)
  if (route !== undefined && existsSync(path.join(ctx.root, target))) return { href: '/' + route + suffix, missing: false }
  if (existsSync(path.join(ctx.root, target))) {
    const encoded = target.split('/').map(encodeURIComponent).join('/')
    return { href: `${repo}/blob/${ctx.ref}/${encoded}${suffix}`, missing: false }
  }
  return { href, missing: true }
}

/** Relative link in a docs/ page → site path, GitHub URL, or unchanged. */
export function rewriteHref(href: string, src: string, ctx: LinkContext): string {
  return resolveDocsLink(href, src, ctx).href
}

/** Normalizes an internal site link: drops the `.html` VitePress emitted and trailing slashes. */
export function cleanSitePath(pathname: string): string {
  let p = pathname.replace(/\.html$/, '').replace(/\/index$/, '')
  if (p.length > 1) p = p.replace(/\/$/, '')
  return p || '/'
}

const LINK = /(!\[[^\]]*\]\([^)\s]*\))|(\]\()([^)\s]+)(\))/g

/**
 * Applies `fn` to every markdown link target outside code fences and inline code spans; image targets go through
 * `img`. A link written inside a code span is an example the page shows, not a link the page has, so the target is
 * tested against the spans: `![`cli`](shot.png)` still has its target outside the span and stays one image, while
 * `![`x](y.png)`](shot.png)` has a target inside one and is left alone.
 */
export function mapLinks(
  md: string,
  fn: (href: string) => string,
  img: (href: string) => string = (h) => h,
): string {
  return outsideFences(md, (chunk) => {
    const spans = codeSpans(chunk)
    return chunk.replace(
      LINK,
      (_m, image: string | undefined, open: string, href: string, close: string, at: number) => {
        const targetAt = image ? at + image.lastIndexOf('(') + 1 : at + open.length
        if (spans.some((span) => targetAt >= span.from && targetAt < span.to)) return _m
        return image
          ? image.replace(/\(([^)\s]*)\)$/, (_x, h: string) => `(${img(h)})`)
          : open + fn(href) + close
      },
    )
  })
}

/** Collects the internal links of a page body (after rewriting) for the dead-link check. */
export function internalLinks(md: string): string[] {
  const found: string[] = []
  mapLinks(md, (h) => (found.push(h), h))
  return found.filter((h) => h.startsWith('/') && !h.startsWith('//'))
}
