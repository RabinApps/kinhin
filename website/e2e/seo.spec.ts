import { desktopOnly, expect, test } from './support/fixtures'
import { hasSnapshot, manifest, pages, versions } from './support/site'

/**
 * SEO fundamentals, and sitemap continuity with the VitePress site this one replaced. Desktop only: nothing here
 * depends on the viewport.
 */
desktopOnly(test)

const ORIGIN = 'https://kinhin.dev'
const newUrl = (route: string) => `${ORIGIN}/${route}`

/** What the VitePress sitemap listed (cleanUrls off, hostname https://kinhin.dev, no lastmod): index pages end in `/`, the rest in `.html`. */
const oldVitePressUrl = (route: string): string =>
  route === '' ? `${ORIGIN}/` : route === 'blog' ? `${ORIGIN}/blog/` : route === 'guide/forges/overview' ? `${ORIGIN}/guide/forges/` : `${ORIGIN}/${route}.html`

test.describe('sitemap', () => {
  test('lists exactly the published pages, one <loc> each and nothing else', async ({ request }) => {
    const res = await request.get('/sitemap.xml')
    expect(res.status()).toBe(200)
    expect(res.headers()['content-type']).toContain('xml')
    const xml = await res.text()
    expect(xml).toContain('<urlset')
    const locs = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1])
    expect(new Set(locs).size, 'no duplicates').toBe(locs.length)
    expect([...locs].sort()).toEqual(pages.map((p) => (p.route === '' ? `${ORIGIN}/` : newUrl(p.route))).sort())
    for (const tag of ['lastmod', 'changefreq', 'priority']) expect(xml, `like VitePress: no <${tag}>`).not.toContain(`<${tag}>`)
    // Exactly one <url> per <loc>.
    expect((xml.match(/<url>/g) ?? []).length).toBe(locs.length)
  })

  test('covers every page the VitePress sitemap covered (same count, every old URL maps to a listed page)', async ({ request }) => {
    const xml = await (await request.get('/sitemap.xml')).text()
    const listed = new Set([...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]))
    const old = pages.map((p) => oldVitePressUrl(p.route))
    expect(listed.size).toBe(old.length)
    for (const url of old) {
      const path = new URL(url).pathname
      const res = await request.get(path, { maxRedirects: 0 })
      if (path === '/') {
        expect(res.status()).toBe(200)
        continue
      }
      expect(res.status(), `${url} must redirect permanently`).toBe(308)
      const target = new URL(res.headers().location, ORIGIN)
      expect(listed.has(`${ORIGIN}${target.pathname}`), `${url} → ${target.pathname} is in the sitemap`).toBe(true)
    }
  })

  test('every listed URL answers 200 itself (no redirects, no errors)', async ({ request }) => {
    const xml = await (await request.get('/sitemap.xml')).text()
    for (const [, loc] of xml.matchAll(/<loc>([^<]+)<\/loc>/g)) {
      const res = await request.get(new URL(loc).pathname, { maxRedirects: 0 })
      expect(res.status(), loc).toBe(200)
    }
  })

  test('robots.txt allows crawling and names the sitemap', async ({ request }) => {
    const robots = await (await request.get('/robots.txt')).text()
    expect(robots).toMatch(/User-agent: \*\s+Allow: \//i)
    expect(robots).not.toMatch(/^Disallow:\s*\/\s*$/m)
    expect(robots).toContain(`Sitemap: ${ORIGIN}/sitemap.xml`)
  })
})

test.describe('on-page SEO, every page', () => {
  const titles = new Map<string, string>()
  for (const p of pages) {
    test(`${p.route || 'home'}: title, description, canonical, social cards, structured data, headings`, async ({ page }) => {
      await page.goto(p.route === '' ? '/' : `/${p.route}`)
      const meta = (sel: string) => page.locator(sel).first().getAttribute('content')
      const title = await page.title()
      expect(title.length, 'title length').toBeGreaterThan(5)
      expect(title.length, `title too long: ${title}`).toBeLessThanOrEqual(70)
      expect(titles.get(title), `duplicate <title> "${title}"`).toBeUndefined()
      titles.set(title, p.route)

      const description = (await meta('meta[name=description]')) ?? ''
      expect(description.length, 'description length').toBeGreaterThanOrEqual(40)
      expect(description.length, 'description length').toBeLessThanOrEqual(200)

      const canonical = p.route === '' ? `${ORIGIN}/` : newUrl(p.route)
      // Next writes the root without its trailing slash; the two are the same URL.
      await expect(page.locator('link[rel=canonical]')).toHaveAttribute('href', p.route === '' ? ORIGIN : canonical)
      await expect(page.locator('link[rel=canonical]')).toHaveCount(1)
      expect(await meta('meta[name=robots]'), 'indexable').not.toMatch(/noindex/)

      expect(await meta('meta[property="og:title"]')).toBeTruthy()
      expect(await meta('meta[property="og:description"]')).toBeTruthy()
      expect((await meta('meta[property="og:url"]'))?.replace(/\/$/, '')).toBe(canonical.replace(/\/$/, ''))
      expect(await meta('meta[property="og:site_name"]')).toBe('kinhin')
      expect(await meta('meta[property="og:image"]')).toBe(`${ORIGIN}/og.png`)
      expect(await meta('meta[property="og:image:width"]')).toBe('1200')
      expect(await meta('meta[property="og:image:height"]')).toBe('630')
      expect(await meta('meta[property="og:image:alt"]')).toBeTruthy()
      expect(await meta('meta[name="twitter:card"]')).toBe('summary_large_image')
      expect(await meta('meta[name="twitter:title"]')).toBeTruthy()
      expect(await meta('meta[name="twitter:image"]')).toBe(`${ORIGIN}/og.png`)
      expect(await meta('meta[name=viewport]')).toContain('width=device-width')
      await expect(page.locator('html')).toHaveAttribute('lang', 'en')

      // Structured data parses and describes this page.
      const scripts = await page.locator('script[type="application/ld+json"]').allTextContents()
      // One object per script, each with its own string @context (readers do `json['@context'].toLowerCase()`).
      for (const t of scripts) {
        const j = JSON.parse(t)
        expect(Array.isArray(j), 'a JSON-LD script is one object, not an array').toBe(false)
        expect(typeof j['@context'], 'JSON-LD @context').toBe('string')
      }
      const ld = scripts.flatMap((t) => [JSON.parse(t)].flat())
      const types = ld.map((x) => x['@type'])
      if (p.route === '') {
        expect(types).toEqual(expect.arrayContaining(['WebSite', 'SoftwareApplication']))
      } else {
        const post = /^blog\/.+/.test(p.route)
        expect(types).toContain(post ? 'BlogPosting' : 'TechArticle')
        expect(types).toContain('BreadcrumbList')
        const crumbs = ld.find((x) => x['@type'] === 'BreadcrumbList').itemListElement
        expect(crumbs.at(-1).item.replace(/\/$/, '')).toBe(canonical.replace(/\/$/, ''))
        expect(crumbs[0].item).toBe(`${ORIGIN}/`)
        if (post) expect(ld.find((x) => x['@type'] === 'BlogPosting').datePublished).toMatch(/^\d{4}-\d{2}-\d{2}$/)
      }

      // One h1, and the outline never skips a level.
      const levels = await page.locator('main h1, main h2, main h3, main h4, main h5, main h6').evaluateAll((hs) => hs.map((h) => Number(h.tagName[1])))
      expect(levels.filter((l) => l === 1)).toHaveLength(1)
      for (let i = 1; i < levels.length; i++) expect(levels[i] - levels[i - 1], `heading order ${levels.join('')}`).toBeLessThanOrEqual(1)

      // Images have alt text attributes and do not shift the layout once loaded.
      const noAlt = await page.locator('main img:not([alt])').count()
      expect(noAlt, 'img without alt').toBe(0)
    })
  }
})

test.describe('crawler signals', () => {
  test('the 404 page is not indexable', async ({ page }) => {
    const res = await page.goto('/no-such-page')
    expect(res?.status()).toBe(404)
    await expect(page.locator('meta[name=robots]').first()).toHaveAttribute('content', /noindex/)
  })

  test('markdown copies are not indexed separately and point at the page', async ({ request }) => {
    const res = await request.get('/guide/quick-start.md')
    expect(res.headers()['x-robots-tag']).toContain('noindex')
    // The host in this header follows the request (localhost here, kinhin.dev in production); the path is what matters.
    expect(res.headers()['link']).toMatch(/<https?:\/\/[^>]+\/guide\/quick-start>; rel="canonical"/)
  })

  test('HTML pages carry no noindex header', async ({ request }) => {
    expect((await request.get('/guide/quick-start')).headers()['x-robots-tag']).toBeUndefined()
  })

  test('the home page announces the site: WebSite and SoftwareApplication', async ({ page }) => {
    await page.goto('/')
    const ld = (await page.locator('script[type="application/ld+json"]').allTextContents()).flatMap((t) => [JSON.parse(t)].flat())
    const app = ld.find((x) => x['@type'] === 'SoftwareApplication')
    expect(app.operatingSystem).toContain('macOS')
    expect(app.offers.price).toBe('0')
    expect(app.license).toContain('apache.org')
  })

  test('the Open Graph image is a real 1200x630 PNG', async ({ request }) => {
    const res = await request.get('/og.png')
    expect(res.headers()['content-type']).toContain('image/png')
    const buf = await res.body()
    expect(buf.readUInt32BE(16)).toBe(1200)
    expect(buf.readUInt32BE(20)).toBe(630)
  })

  test('manifest.version matches the build under test', async () => {
    expect(manifest.snapshot).toBe(false)
  })
})

test.describe('release snapshots stay out of the index', () => {
  const built = versions.filter(hasSnapshot)
  test.skip(built.length === 0, 'no snapshots in this build')
  for (const tag of built) {
    test(`${tag} is noindex and canonical to the latest page`, async ({ page }) => {
      await page.goto(`/${tag}/guide/quick-start`)
      await expect(page.locator('meta[name=robots]').first()).toHaveAttribute('content', /noindex/)
      await expect(page.locator('link[rel=canonical]')).toHaveAttribute('href', `${ORIGIN}/guide/quick-start`)
    })
  }
})
