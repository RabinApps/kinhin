/**
 * Where a request for the markdown copy of a page should be rewritten to.
 *
 * The latest docs serve markdown from a route handler (`/md/<route>`); a release snapshot (`/<tag>/…`) is a static
 * export that ships its `.md` files as plain assets next to the pages (`/<tag>/guide/quick-start.md`).
 */
export function markdownRewrite(pathname: string, versions: readonly string[]): string {
  const clean = pathname.replace(/\/+$/, '')
  const tag = versions.find((v) => clean === `/${v}` || clean.startsWith(`/${v}/`))
  if (tag) return clean === `/${tag}` ? `/${tag}/index.md` : `${clean}.md`
  return `/md/${clean === '' ? 'index' : clean.replace(/^\//, '')}`
}

/** The `.md` URL a page advertises (`Link: rel="alternate"`). */
export function markdownUrl(pathname: string, versions: readonly string[]): string {
  const target = markdownRewrite(pathname, versions)
  return target.startsWith('/md/') ? `${target.slice(3)}.md` : target
}

/** True for `/<tag>` and `/<tag>/…` of a release snapshot. */
export const isSnapshotPath = (pathname: string, versions: readonly string[]): boolean =>
  versions.some((v) => pathname === `/${v}` || pathname.startsWith(`/${v}/`))

/** A URL path made of ordinary characters only: safe to put in a header or a rewrite target. */
export const isSafePath = (pathname: string): boolean => /^\/[A-Za-z0-9/_.~%+-]*$/.test(pathname) && !pathname.includes('..')

/**
 * A release snapshot that was removed from versions.json (old beta tags once 0.1.0 ships): its URL answers with a permanent redirect to
 * the same page on the latest site instead of a 404. Returns the target path, or null when the path is not an unlisted version.
 */
export function removedSnapshotRedirect(pathname: string, versions: readonly string[]): string | null {
  const m = /^\/v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?=\/|$)/.exec(pathname)
  if (!m) return null
  const tag = m[0].slice(1)
  if (versions.includes(tag)) return null
  const rest = pathname.slice(m[0].length).replace(/\/+$/, '')
  return rest === '' ? '/' : rest
}
