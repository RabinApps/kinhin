import { expect, test } from '@playwright/test'
import { hasPublic, hasSnapshot, pages, versions } from './support/site'

/**
 * A crawl of the rendered site: every internal link and image on every page resolves, and every same-site anchor
 * points at a heading that exists. This catches what the build's dead-link check cannot (links made by components).
 */
const origin = 'https://kinhin.dev'

test('every internal link, image and asset on every page resolves', async ({ request }) => {
  test.setTimeout(180_000)
  const targets = new Map<string, string>() // path → first page that links to it
  const anchors: { from: string; path: string; id: string }[] = []
  for (const p of pages) {
    const from = `/${p.route}`
    const html = await (await request.get(from)).text()
    // Links to our own pages use clean URLs (external docs sites legitimately end in .html).
    expect(html, `${from}: no leftover .html links to this site`).not.toMatch(/href="(?:https:\/\/kinhin\.dev)?\/[^"]*\.html[#"]/)
    for (const [, raw] of html.matchAll(/(?:href|src)="([^"#]*)(#[^"]*)?"/g)) {
      let path = raw
      // Only our own origin counts: `https://kinhin.dev.evil.example/` must not be treated as ours.
      if (path === origin) path = '/'
      else if (path.startsWith(`${origin}/`)) path = path.slice(origin.length)
      if (!path.startsWith('/') || path.startsWith('//')) continue
      // The Sparkle feed is fetched from the latest release by CI at deploy time; a local build may not have it.
      if (path === '/appcast.xml' && !hasPublic('appcast.xml')) continue
      // The version picker links every release; a snapshot this build did not produce (no tag locally) is not a broken link.
      if (versions.some((v) => (path === `/${v}` || path.startsWith(`/${v}/`)) && !hasSnapshot(v))) continue
      path = path.replace(/&amp;/g, '&')
      if (!targets.has(path)) targets.set(path, from)
    }
    for (const [, path, id] of html.matchAll(/href="(\/[^"#]*)#([^"]+)"/g)) anchors.push({ from, path: path.replace(/\/$/, '') || '/', id })
  }
  expect(targets.size).toBeGreaterThan(100)
  const broken: string[] = []
  for (const [path, from] of targets) {
    const res = await request.get(path, { maxRedirects: 0 })
    if (![200, 307, 308].includes(res.status())) broken.push(`${res.status()} ${path} (linked from ${from})`)
  }
  expect(broken).toEqual([])

  // Anchors are checked against the ids in the target page's real HTML (h4s and hand-written ids count too).
  const idsOf = new Map<string, Set<string>>()
  const idsFor = async (path: string): Promise<Set<string> | undefined> => {
    if (!idsOf.has(path)) {
      const res = await request.get(path, { maxRedirects: 0 })
      idsOf.set(path, res.status() === 200 ? new Set([...(await res.text()).matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])) : new Set())
    }
    return idsOf.get(path)
  }
  const dangling: string[] = []
  for (const a of anchors) {
    const ids = await idsFor(a.path)
    if (ids && ids.size > 0 && !ids.has(a.id)) dangling.push(`${a.from} → ${a.path}#${a.id}`)
  }
  expect([...new Set(dangling)]).toEqual([])
})

test('external links are https and carry no tracking or placeholder hosts', async ({ request }) => {
  const bad: string[] = []
  for (const p of pages) {
    const html = await (await request.get(`/${p.route}`)).text()
    for (const [, url] of html.matchAll(/href="(https?:\/\/[^"]+)"/g)) {
      if (url.startsWith('http://')) bad.push(`${p.route}: ${url}`)
      if (/localhost|127\.0\.0\.1|example\.invalid/.test(url)) bad.push(`${p.route}: ${url}`)
    }
  }
  expect(bad).toEqual([])
})
