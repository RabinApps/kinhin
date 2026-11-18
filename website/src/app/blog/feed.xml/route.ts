import { siteURL } from '../../../../site.config.ts'
import { getManifest } from '../../../lib/content'

export const dynamic = 'force-static'

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

/** Atom feed of the release posts, newest first (dates come from the blog index, see scripts/content/build.ts). */
export function GET() {
  const posts = getManifest()
    .pages.filter((p) => /^blog\/.+/.test(p.route) && p.date)
    .sort((a, b) => b.date!.localeCompare(a.date!))
  const updated = posts[0]?.date ?? '2026-01-01'
  const xml = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>kinhin blog</title>
  <subtitle>Release notes and field notes from kinhin.</subtitle>
  <id>${siteURL}/blog</id>
  <link href="${siteURL}/blog"/>
  <link rel="self" type="application/atom+xml" href="${siteURL}/blog/feed.xml"/>
  <updated>${updated}T12:00:00Z</updated>
  <author><name>Alex Rabin</name></author>
${posts
  .map(
    (p) => `  <entry>
    <title>${esc(p.title)}</title>
    <id>${siteURL}/${p.route}</id>
    <link href="${siteURL}/${p.route}"/>
    <link rel="alternate" type="text/markdown" href="${siteURL}/${p.route}.md"/>
    <updated>${p.date}T12:00:00Z</updated>
    <summary>${esc(p.description)}</summary>
  </entry>`,
  )
  .join('\n')}
</feed>
`
  return new Response(xml, { headers: { 'content-type': 'application/atom+xml; charset=utf-8', 'cache-control': 'public, max-age=300, s-maxage=3600', 'x-content-type-options': 'nosniff' } })
}
