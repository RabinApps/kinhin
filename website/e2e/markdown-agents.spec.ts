import { expect, test } from '@playwright/test'
import { pageOf, pages, sidebarLinks } from './support/site'

/** Markdown for agents: the `.md` copies, Accept negotiation, llms.txt and friends. API level, no browser. */

const BROWSER_ACCEPT = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
const mdUrl = (route: string) => (route === '' ? '/index.md' : `/${route}.md`)
/** The body without fenced code, where example markdown legitimately contains relative links and `:::`. */
const outsideFences = (md: string) => md.replace(/^(```|~~~)[\s\S]*?^\1/gm, '')

test.describe('.md copies', () => {
  for (const p of pages) {
    test(`${p.route || 'home'}.md is clean markdown`, async ({ request }) => {
      const res = await request.get(mdUrl(p.route))
      expect(res.status()).toBe(200)
      expect(res.headers()['content-type']).toContain('text/markdown')
      expect(Number(res.headers()['x-markdown-tokens'])).toBeGreaterThan(0)
      expect(res.headers()['x-robots-tag']).toContain('noindex')
      const body = await res.text()
      expect(body.startsWith('# '), `starts with a title: ${body.slice(0, 60)}`).toBe(true)
      const prose = outsideFences(body)
      expect(body.startsWith('---'), 'no frontmatter').toBe(false)
      expect(prose, 'container directives are gone').not.toMatch(/^:{3,}/m)
      expect(prose, 'no Vue components').not.toMatch(/<(SearchNextSteps|DocsGrid|AudienceTabs|template)\b/)
      expect(prose, 'no docs-sync markers').not.toContain('docs-sync:')
      // Links to other pages are absolute .md URLs, so an agent can follow them without the site.
      const relative = [...prose.matchAll(/(?<!!)\]\(((?!https?:|#|mailto:)[^)\s]+)\)/g)].map((m) => m[1])
      expect(relative, 'no relative links').toEqual([])
      for (const [, url] of prose.matchAll(/\]\((https:\/\/kinhin\.dev\/[^)\s#]+)/g)) {
        expect(url, 'site links point at .md copies').toMatch(/\.md$|\.txt$|\.xml$|\.(mp4|webm|png|svg)$/)
      }
    })
  }

  test('the quick start copy starts with its title and has its install command', async ({ request }) => {
    const body = await (await request.get('/guide/quick-start.md')).text()
    expect(body.split('\n')[0]).toBe('# Quick start')
    expect(body).toContain('curl -fsSL https://github.com/RabinApps/kinhin/releases/latest/download/install.sh | bash')
  })

  test('the tab and container syntax turns into labelled text', async ({ request }) => {
    const body = await (await request.get('/guide/quick-start.md')).text()
    expect(body).toContain('**If you are an AI agent**')
    expect(body).toContain('**Warning: Beta**')
  })

  test('a search-intent page ends with its next steps', async ({ request }) => {
    const body = await (await request.get('/how-many-macos-vms-can-run-at-once.md')).text()
    expect(body).toContain('## Next steps')
    expect(body).toContain('https://kinhin.dev/guide/quick-start.md')
  })

  test('an unknown copy is a 404', async ({ request }) => {
    expect((await request.get('/no-such-page.md')).status()).toBe(404)
  })
})

test.describe('Accept: text/markdown', () => {
  for (const p of pages) {
    test(`${p.route || 'home'} negotiates to the same markdown as its .md copy`, async ({ request }) => {
      const negotiated = await request.get(p.route === '' ? '/' : `/${p.route}`, { headers: { accept: 'text/markdown' } })
      expect(negotiated.status()).toBe(200)
      expect(negotiated.headers()['content-type']).toContain('text/markdown')
      expect(negotiated.headers()['vary']?.toLowerCase()).toContain('accept')
      expect(await negotiated.text()).toBe(await (await request.get(mdUrl(p.route))).text())
    })
  }

  test('browsers and unspecific clients keep getting HTML', async ({ request }) => {
    for (const accept of [BROWSER_ACCEPT, '*/*', 'text/markdown;q=0.5, text/html', 'text/html, text/markdown', 'text/markdown;q=0']) {
      const res = await request.get('/guide/quick-start', { headers: { accept } })
      expect(res.headers()['content-type'], accept).toContain('text/html')
    }
    expect((await request.get('/guide/quick-start')).headers()['content-type']).toContain('text/html')
  })

  test('agents that prefer markdown get it, with an HTML fallback listed', async ({ request }) => {
    for (const accept of ['text/markdown', 'text/markdown, text/html;q=0.8', 'text/markdown;q=1.0, */*;q=0.1']) {
      const res = await request.get('/guide/quick-start', { headers: { accept } })
      expect(res.headers()['content-type'], accept).toContain('text/markdown')
    }
  })

  test('HTML pages advertise their markdown copy and vary on Accept', async ({ request }) => {
    const res = await request.get('/guide/quick-start')
    expect(res.headers()['link']).toContain('</guide/quick-start.md>; rel="alternate"; type="text/markdown"')
    expect(res.headers()['vary']?.toLowerCase()).toContain('accept')
  })

  test('an unknown page stays a 404 under negotiation', async ({ request }) => {
    const res = await request.get('/no-such-page', { headers: { accept: 'text/markdown' } })
    expect(res.status()).toBe(404)
  })
})

test.describe('llms.txt, llms-full.txt, sitemap and robots', () => {
  test('llms.txt follows the index format and lists every sidebar page once', async ({ request }) => {
    const res = await request.get('/llms.txt')
    expect(res.status()).toBe(200)
    expect(res.headers()['content-type']).toContain('text/plain')
    const txt = await res.text()
    expect(txt.startsWith('# kinhin\n\n> ')).toBe(true)
    const urls = [...txt.matchAll(/^- \[[^\]]+\]\((https:\/\/kinhin\.dev\/[^)]+)\)/gm)].map((m) => m[1])
    expect(new Set(urls).size, 'no duplicate entries').toBe(urls.length)
    for (const l of sidebarLinks) {
      if (pages.some((p) => '/' + p.route === l.link)) expect(urls, l.link).toContain(`https://kinhin.dev${l.link}.md`)
    }
    expect(txt).toContain('## Blog')
  })

  test('every URL in llms.txt fetches', async ({ request }) => {
    const txt = await (await request.get('/llms.txt')).text()
    const paths = [...txt.matchAll(/\((https:\/\/kinhin\.dev(\/[^)]+))\)/g)].map((m) => m[2])
    expect(paths.length).toBeGreaterThan(60)
    for (const p of paths) {
      const res = await request.get(p)
      expect(res.status(), p).toBe(200)
      expect(res.headers()['content-type'], p).toContain('text/markdown')
    }
  })

  test('llms-full.txt carries every page with its source URL', async ({ request }) => {
    const txt = await (await request.get('/llms-full.txt')).text()
    for (const p of pages) expect(txt, p.route).toContain(`Source: https://kinhin.dev/${p.route === '' ? 'index' : p.route}.md`)
    expect(txt).toContain(pageOf('guide/quick-start').title)
  })

  test('sitemap.xml lists every page and robots.txt points at it', async ({ request }) => {
    const sitemap = await (await request.get('/sitemap.xml')).text()
    for (const p of pages) expect(sitemap, p.route).toContain(`<loc>https://kinhin.dev/${p.route}`)
    const robots = await (await request.get('/robots.txt')).text()
    expect(robots).toMatch(/User-Agent: \*\s+Allow: \//i)
    expect(robots).toContain('Sitemap: https://kinhin.dev/sitemap.xml')
  })

  test('the search index is MiniSearch JSON covering the docs', async ({ request }) => {
    const idx = await (await request.get('/search-index.json')).json()
    expect(idx.documentCount).toBeGreaterThanOrEqual(pages.length - 1)
    expect(Object.keys(idx)).toEqual(expect.arrayContaining(['index', 'documentIds', 'fieldIds']))
  })
})
