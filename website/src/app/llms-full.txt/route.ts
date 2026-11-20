import { readGenerated } from '../../lib/content'

export const dynamic = 'force-static'

export function GET() {
  return new Response(readGenerated('llms-full.txt'), {
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=300, s-maxage=3600' },
  })
}
