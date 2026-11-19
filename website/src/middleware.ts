import { NextResponse, type NextRequest } from 'next/server'
import versions from '../versions.json'
import { prefersMarkdown } from './lib/accept'
import { securityHeaders } from './lib/headers'
import { isSafePath, markdownRewrite, markdownUrl } from './lib/route'

/**
 * Markdown for agents. A page URL asked for with `Accept: text/markdown` returns the page's markdown copy
 * (generated at build time, see scripts/content/build.ts); every HTML page advertises its copy with a
 * `Link: rel="alternate"` header and `Vary: Accept`, so caches keep the two apart. Release snapshots (`/<tag>/…`)
 * negotiate the same way, rewriting to their static `.md` files.
 *
 * The same pass adds the security headers every HTML response should carry.
 */

export function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl
  // Files (`.md`, images, the sitemap) are served as they are.
  if (/\.[a-z0-9]+$/i.test(pathname)) return NextResponse.next()
  if (prefersMarkdown(req.headers.get('accept'))) {
    const url = req.nextUrl.clone()
    url.pathname = markdownRewrite(pathname, versions)
    return NextResponse.rewrite(url)
  }
  const res = NextResponse.next()
  res.headers.append('vary', 'Accept')
  // The path comes from the request: only advertise it when it is plainly a path (no `>`, quotes or control characters).
  if (isSafePath(pathname)) res.headers.set('link', `<${markdownUrl(pathname, versions)}>; rel="alternate"; type="text/markdown"`)
  for (const [k, v] of Object.entries(securityHeaders)) res.headers.set(k, v)
  return res
}

export const config = {
  // Pages only: not Next internals, the markdown route handler or API routes.
  matcher: ['/((?!_next/|md/|api/).*)'],
}
