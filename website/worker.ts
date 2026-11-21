import openNext from './.open-next/worker.js'
import versions from './versions.json'
import { accessToken, fetchAccessKeys, verifyAccessJwt } from './src/lib/access'
import { prefersMarkdown } from './src/lib/accept'
import { securityHeaders } from './src/lib/headers'
import { isSnapshotPath, markdownRewrite, removedSnapshotRedirect } from './src/lib/route'

/**
 * The Worker's entry point: OpenNext's handler, with one addition. Release snapshots (`/<tag>/…`) are static files, and the
 * assets layer would serve them without running any code, so `Accept: text/markdown` could not reach the middleware.
 * wrangler.jsonc's `assets.run_worker_first` sends `/v*` here; a snapshot page asked for as markdown gets its `.md` file,
 * anything else is served from the assets (with `Vary: Accept`, like the pages OpenNext serves).
 */
interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> }
  /** `dev` on dev.kinhin.dev: every response the Worker serves is `noindex, nofollow`. */
  SITE_ENV?: string
  /** `true` on dev: requests must carry a valid Cloudflare Access token (checked again here, whatever Access at the edge did). */
  REQUIRE_ACCESS?: string
  ACCESS_TEAM_DOMAIN?: string
  ACCESS_AUD?: string
}

const forbidden = () => new Response('Forbidden', { status: 403, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } })

/**
 * dev.kinhin.dev is behind Cloudflare Access, which stops anonymous visitors at the edge. This second check keeps the pages the
 * Worker serves closed even if the Access application is removed, disabled or attached to the wrong hostname. (Static files
 * that the assets layer serves without running the Worker, such as /_next/static, rely on Access at the edge alone.)
 * It fails closed: Access required but not configured is a 503, never an open site.
 */
async function guard(request: Request, env: Env): Promise<Response | null> {
  if (env.REQUIRE_ACCESS !== 'true') return null
  if (!env.ACCESS_TEAM_DOMAIN || !env.ACCESS_AUD) return new Response('Access is required but not configured', { status: 503, headers: { 'cache-control': 'no-store' } })
  const teamDomain = env.ACCESS_TEAM_DOMAIN
  try {
    const result = await verifyAccessJwt(accessToken(request.headers), { teamDomain, aud: env.ACCESS_AUD }, (refresh) => fetchAccessKeys(teamDomain, refresh))
    return result.ok ? null : forbidden()
  } catch {
    return forbidden() // the key set could not be fetched: refuse rather than let the request through
  }
}

function withHsts(res: Response): Response {
  res.headers.set('strict-transport-security', securityHeaders['strict-transport-security'])
  return res
}

export default {
  async fetch(request: Request, env: Env, ctx: unknown): Promise<Response> {
    const denied = await guard(request, env)
    if (denied) return withHsts(denied)
    const res = await route(request, env, ctx)
    // The middleware and public/_headers skip responses the Worker builds itself (markdown, llms.txt, the feed, redirects).
    const out = new Response(res.body, res)
    out.headers.set('strict-transport-security', securityHeaders['strict-transport-security'])
    if (env.SITE_ENV === 'dev') out.headers.set('x-robots-tag', 'noindex, nofollow')
    return out
  },
}

async function route(request: Request, env: Env, ctx: unknown): Promise<Response> {
  {
    const url = new URL(request.url)
    // A snapshot that is no longer in versions.json (old betas after 0.1.0) lands on the same page of the latest site.
    const moved = removedSnapshotRedirect(url.pathname, versions)
    if (moved) return new Response(null, { status: 301, headers: { location: moved + url.search, 'cache-control': 'public, max-age=3600' } })
    if (!isSnapshotPath(url.pathname, versions)) return (openNext as { fetch: (r: Request, e: Env, c: unknown) => Promise<Response> }).fetch(request, env, ctx)
    const wantsMarkdown = !/\.[a-z0-9]+$/i.test(url.pathname) && prefersMarkdown(request.headers.get('accept'))
    if (wantsMarkdown) {
      const target = new URL(request.url)
      target.pathname = markdownRewrite(url.pathname, versions)
      const res = await env.ASSETS.fetch(new Request(target, request))
      const out = new Response(res.body, res)
      out.headers.set('content-type', 'text/markdown; charset=utf-8')
      out.headers.set('x-robots-tag', 'noindex')
      out.headers.append('vary', 'Accept')
      return out
    }
    // html_handling is "none" (OpenNext requires it once the Worker runs first), so a page URL is mapped to its .html file here.
    const isFile = /\.[a-z0-9]+$/i.test(url.pathname)
    const clean = url.pathname.replace(/\/+$/, '')
    const tag = versions.find((v) => clean === `/${v}` || clean.startsWith(`/${v}/`))!
    const target = new URL(request.url)
    if (!isFile) target.pathname = clean === `/${tag}` ? `/${tag}/index.html` : `${clean}.html`
    let res = await env.ASSETS.fetch(new Request(target, request))
    if (res.status === 404 && !isFile) {
      target.pathname = `/${tag}/404.html`
      const notFound = await env.ASSETS.fetch(new Request(target, request))
      res = new Response(notFound.body, { status: 404, headers: notFound.headers })
    }
    const out = new Response(res.body, res)
    if (!isFile) out.headers.append('vary', 'Accept')
    return out
  }
}
