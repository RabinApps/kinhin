import openNext from './.open-next/worker.js'
import versions from './versions.json'
import { prefersMarkdown } from './src/lib/accept'
import { isSnapshotPath, markdownRewrite } from './src/lib/route'

/**
 * The Worker's entry point: OpenNext's handler, with one addition. Release snapshots (`/<tag>/…`) are static files, and the
 * assets layer would serve them without running any code, so `Accept: text/markdown` could not reach the middleware.
 * wrangler.jsonc's `assets.run_worker_first` sends `/v*` here; a snapshot page asked for as markdown gets its `.md` file,
 * anything else is served from the assets (with `Vary: Accept`, like the pages OpenNext serves).
 */
interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> }
}

export default {
  async fetch(request: Request, env: Env, ctx: unknown): Promise<Response> {
    const url = new URL(request.url)
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
  },
}
