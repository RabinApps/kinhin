import { readGenerated } from '../../lib/content'

export const dynamic = 'force-static'

export function GET() {
  return new Response(readGenerated('search-index.json'), {
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'public, max-age=300, s-maxage=3600' },
  })
}
