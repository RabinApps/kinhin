import { estimateTokens } from '../../../lib/accept'
import { getManifest, getMarkdown } from '../../../lib/content'

/**
 * The markdown copy of a page: `/guide/quick-start.md` (rewritten here by next.config) and
 * `Accept: text/markdown` on `/guide/quick-start` (rewritten here by src/middleware.ts).
 */
export const dynamic = 'force-static'
export const dynamicParams = false

export function generateStaticParams() {
  // Release snapshots are static exports: their .md files are copied in by scripts/build-snapshot.sh instead.
  if (process.env.NEXT_PUBLIC_DOCS_VERSION) return [{ slug: ['index'] }]
  return getManifest().pages.map((p) => ({ slug: p.route === '' ? ['index'] : p.route.split('/') }))
}

export async function GET(_req: Request, { params }: { params: Promise<{ slug: string[] }> }) {
  const slug = (await params).slug.join('/')
  const body = getMarkdown(slug)
  if (body === undefined) return new Response('Not found\n', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } })
  return new Response(body, {
    headers: {
      'content-type': 'text/markdown; charset=utf-8',
      'cache-control': 'public, max-age=300, s-maxage=3600',
      'x-markdown-tokens': String(estimateTokens(body)),
      'x-content-type-options': 'nosniff',
      vary: 'Accept',
      'x-robots-tag': 'noindex',
      link: `<https://kinhin.dev/${slug === 'index' ? '' : slug}>; rel="canonical"`,
    },
  })
}
