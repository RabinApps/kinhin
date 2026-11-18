import { desktopOnly, expect, test } from './support/fixtures'
import { pages, urlOf } from './support/site'

desktopOnly(test)

/** The <title> rules in src/lib/seo.ts: forge notes say what they are; long titles are cut near 60 characters. */
function expectedTitle(p: { route: string; title: string }): string {
  const t = /^guide\/forges\/(?!overview$)/.test(p.route) ? `${p.title}: forge API notes` : p.title
  if (t.length <= 60) return t
  const cut = t.slice(0, 59)
  const at = Math.max(cut.lastIndexOf(','), cut.lastIndexOf(' '))
  return cut.slice(0, at > 20 ? at : 59).replace(/[\s,;:.\-–—]+$/, '') + '…'
}

test.describe('every published page', () => {
  for (const p of pages) {
    test(`${p.route || 'home'} renders cleanly`, async ({ page, problems }) => {
      const res = await page.goto(urlOf(p.route))
      expect(res?.status()).toBe(200)
      await expect(page.locator('main')).toBeVisible()
      if (p.route === '') {
        await expect(page.locator('h1')).toHaveCount(1)
      } else {
        await expect(page.locator('h1')).toHaveCount(1)
        await expect(page.locator('h1')).toHaveText(p.title)
        await expect(page).toHaveTitle(`${expectedTitle(p)} · kinhin`)
        await expect(page.locator('link[rel=canonical]')).toHaveAttribute('href', `https://kinhin.dev/${p.route}`)
        await expect(page.locator('link[rel=alternate][type="text/markdown"]')).toHaveAttribute('href', `https://kinhin.dev/${p.route}.md`)
      }
      // The old "Home" breadcrumb and header must be there on every page.
      await expect(page.locator('header.site-header')).toBeVisible()
      await expect(page.locator('footer.site-footer')).toBeVisible()
      expect(problems, problems.join('\n')).toEqual([])
    })
  }
})

test.describe('URLs', () => {
  test('an unknown page is a 404 with the not-found page', async ({ page }) => {
    const res = await page.goto('/definitely-not-a-page')
    expect(res?.status()).toBe(404)
    await expect(page.getByRole('heading', { name: 'This runner went offline.' })).toBeVisible()
    await page.getByRole('link', { name: 'Back to docs' }).click()
    await expect(page).toHaveURL(/\/guide\/quick-start$/)
  })

  test('the old VitePress .html URLs redirect to the clean URL', async ({ request }) => {
    for (const [from, to] of [
      ['/how-many-macos-vms-can-run-at-once.html', '/how-many-macos-vms-can-run-at-once'],
      ['/guide/quick-start.html', '/guide/quick-start'],
    ]) {
      const res = await request.get(from, { maxRedirects: 0 })
      expect(res.status(), from).toBe(308)
      expect(new URL(res.headers().location, 'http://x').pathname).toBe(to)
    }
  })

  test('a trailing slash redirects to the page, and the old forge overview address to its new page', async ({ request }) => {
    for (const [from, to] of [['/guide/quick-start/', '/guide/quick-start'], ['/blog/', '/blog'], ['/guide/forges/', '/guide/forges/overview']]) {
      const res = await request.get(from, { maxRedirects: 0 })
      expect(res.status(), from).toBe(308)
      expect(new URL(res.headers().location, 'http://x').pathname, from).toBe(to)
    }
  })

  test('the forge overview lives at /guide/forges/overview', async ({ request }) => {
    expect((await request.get('/guide/forges/overview')).status()).toBe(200)
    expect((await request.get('/guide/forges')).status()).toBe(200)
  })

  test('the blog index and the search-intent pages resolve at the root', async ({ request }) => {
    expect((await request.get('/blog')).status()).toBe(200)
    expect((await request.get('/how-to-run-github-actions-on-a-self-hosted-mac')).status()).toBe(200)
  })
})
