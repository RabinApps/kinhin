import { existsSync, readdirSync } from 'node:fs'
import path from 'node:path'

/**
 * Which markdown files the site publishes, and at which URL. This is the old VitePress `srcExclude` +
 * `rewrites` table: `docs/` is the single source for the guides, `website/` holds the site-only pages.
 *
 *   website/index.md                 → /
 *   website/{guide,cli,blog}/X.md    → /{guide,cli,blog}/X      (blog/index.md → /blog)
 *   website/search/X.md              → /X                       (search-intent pages live at the root)
 *   docs/why.md                      → /guide/why-kinhin
 *   docs/forges/README.md            → /guide/forges/overview   (docs/forges.md owns /guide/forges)
 *   docs/forges/X.md, docs/X.md      → /guide/forges/X, /guide/X
 */

/** `docs/` pages the site does not publish: links to them go to GitHub instead. */
export const unpublished = new Set(['docs/app.md', 'docs/adding-a-forge.md'])

export interface Source {
  /** Repo-relative path, e.g. `docs/why.md`. */
  src: string
  /** URL path without a leading slash; `''` is the home page. */
  route: string
}

const docRenames: Record<string, string> = {
  'docs/why.md': 'guide/why-kinhin',
  'docs/forges/README.md': 'guide/forges/overview',
}

export function routeFor(src: string): string | undefined {
  if (src === 'website/index.md') return ''
  let m = /^website\/(guide|cli|blog)\/([^/]+)\.md$/.exec(src)
  if (m) return m[2] === 'index' ? m[1] : `${m[1]}/${m[2]}`
  m = /^website\/search\/([^/]+)\.md$/.exec(src)
  if (m) return m[1]
  if (unpublished.has(src)) return undefined
  if (docRenames[src]) return docRenames[src]
  m = /^docs\/(forges\/)?([^/]+)\.md$/.exec(src)
  if (m) return `guide/${m[1] ?? ''}${m[2]}`
  return undefined
}

function mdIn(root: string, dir: string): string[] {
  const abs = path.join(root, dir)
  if (!existsSync(abs)) return []
  return readdirSync(abs, { withFileTypes: true })
    .filter((e) => e.isFile() && e.name.endsWith('.md'))
    .map((e) => `${dir}/${e.name}`)
    .sort()
}

/** Every published source under `root` (the repo root, or a checkout of an old tag). */
export function collect(root: string): Source[] {
  const files = [
    'website/index.md',
    ...['guide', 'cli', 'blog', 'search'].flatMap((d) => mdIn(root, `website/${d}`)),
    ...mdIn(root, 'docs'),
    ...mdIn(root, 'docs/forges'),
  ].filter((f) => existsSync(path.join(root, f)))
  const byRoute = new Map<string, Source>()
  for (const src of files) {
    const route = routeFor(src)
    if (route === undefined) continue
    const prior = byRoute.get(route)
    // Same URL from two files: the site-only page wins, as it did under VitePress.
    if (prior && prior.src.startsWith('website/') && src.startsWith('docs/')) continue
    byRoute.set(route, { src, route })
  }
  return [...byRoute.values()]
}
