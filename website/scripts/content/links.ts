import { existsSync } from 'node:fs'
import path from 'node:path'
import { outsideFences } from './fences.ts'

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

/** Relative link in a docs/ page → site path, GitHub URL, or unchanged. */
export function rewriteHref(href: string, src: string, ctx: LinkContext): string {
  if (!src.startsWith('docs/') || external.test(href) || href.startsWith('/')) return href
  const [file, anchor] = href.split('#')
  const target = path.posix.normalize(path.posix.join(path.posix.dirname(src), file))
  const hash = anchor ? `#${anchor}` : ''
  if (target === 'README.md') return '/'
  const route = ctx.routes.get(target)
  if (route !== undefined && existsSync(path.join(ctx.root, target))) return '/' + route + hash
  if (existsSync(path.join(ctx.root, target))) return `${repo}/blob/${ctx.ref}/${target}${hash}`
  return href
}

/** Normalizes an internal site link: drops the `.html` VitePress emitted and trailing slashes. */
export function cleanSitePath(pathname: string): string {
  let p = pathname.replace(/\.html$/, '').replace(/\/index$/, '')
  if (p.length > 1) p = p.replace(/\/$/, '')
  return p || '/'
}

const LINK = /(!\[[^\]]*\]\([^)\s]*\))|(\]\()([^)\s]+)(\))/g

/** Applies `fn` to every markdown link target outside code fences; image targets go through `img`. */
export function mapLinks(
  md: string,
  fn: (href: string) => string,
  img: (href: string) => string = (h) => h,
): string {
  return outsideFences(md, (chunk) =>
    chunk.replace(LINK, (_m, image: string | undefined, open: string, href: string, close: string) =>
      image ? image.replace(/\(([^)\s]*)\)$/, (_x, h: string) => `(${img(h)})`) : open + fn(href) + close,
    ),
  )
}

/** Collects the internal links of a page body (after rewriting) for the dead-link check. */
export function internalLinks(md: string): string[] {
  const found: string[] = []
  mapLinks(md, (h) => (found.push(h), h))
  return found.filter((h) => h.startsWith('/') && !h.startsWith('//'))
}
