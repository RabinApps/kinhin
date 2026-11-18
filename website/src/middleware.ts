import { NextResponse, type NextRequest } from 'next/server'
import versions from '../versions.json'
import { prefersMarkdown } from './lib/accept'
import { isSafePath, markdownRewrite, markdownUrl } from './lib/route'

/**
 * Markdown for agents. A page URL asked for with `Accept: text/markdown` returns the page's markdown copy
 * (generated at build time, see scripts/content/build.ts); every HTML page advertises its copy with a
 * `Link: rel="alternate"` header and `Vary: Accept`, so caches keep the two apart. Release snapshots (`/<tag>/…`)
 * negotiate the same way, rewriting to their static `.md` files.
 *
 * The same pass adds the security headers every HTML response should carry.
 */

// Scripts: the theme bootstrap and Next's own payload are inline, hence 'unsafe-inline' (pages are prerendered, so there is no
// per-request nonce); markdown is sanitised at build time. Everything else is same-origin: the page makes no third-party calls.
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: https:",
  "media-src 'self'",
  "font-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ')

export const securityHeaders: Record<string, string> = {
  'content-security-policy': CSP,
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  'x-frame-options': 'DENY',
  'cross-origin-opener-policy': 'same-origin',
  'x-permitted-cross-domain-policies': 'none',
}

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
