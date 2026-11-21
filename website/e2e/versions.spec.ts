import { desktopOnly, expect, hydrated, test } from './support/fixtures'
import { hasSnapshot, versions } from './support/site'

desktopOnly(test)

test.describe('version picker', () => {
  test('lists the latest docs and every release in versions.json', async ({ page }) => {
    await page.goto('/')
    const picker = page.locator('details.version')
    await expect(picker.locator('summary')).toHaveText('latest')
    await picker.locator('summary').click()
    const menu = picker.locator('.version-menu')
    await expect(menu.getByRole('link', { name: 'Latest (main)' })).toHaveAttribute('href', 'https://kinhin.dev/')
    for (const v of versions) await expect(menu.getByRole('link', { name: v, exact: true })).toHaveAttribute('href', `https://kinhin.dev/${v}/`)
    await expect(menu.getByRole('link')).toHaveCount(versions.length + 1)
  })

  test('the latest site shows no old-version banner', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.locator('.version-banner')).toHaveCount(0)
  })
})

test.describe('removed release snapshots', () => {
  test('an unlisted version redirects permanently to the same page on the latest site', async ({ request }) => {
    for (const [from, to] of [
      ['/v0.0.0-gone/guide/quick-start', '/guide/quick-start'],
      ['/v0.0.0-gone/guide/quick-start/', '/guide/quick-start'],
      ['/v0.0.0-gone/', '/'],
      ['/v0.0.0-gone', '/'],
      ['/v9.9.9/blog/beta-2.md', '/blog/beta-2.md'],
    ]) {
      const res = await request.get(from, { maxRedirects: 0 })
      expect(res.status(), from).toBe(301)
      expect(res.headers().location, from).toBe(to)
    }
    expect((await request.get('/v0.0.0-gone/guide/quick-start?x=1', { maxRedirects: 0 })).headers().location).toBe('/guide/quick-start?x=1')
  })

  test('an unlisted version never redirects to another host (open redirect)', async ({ request }) => {
    for (const from of ['/v9.9.9//evil.example/x', '/v9.9.9///evil.example', '/v9.9.9//evil.example/', '/v0.0.0-gone//evil.example?a=1']) {
      const res = await request.get(from, { maxRedirects: 0 })
      const to = res.headers().location ?? ''
      expect(res.status(), from).toBe(301)
      // Resolved against the site, the target must stay on the site: `//host/…` would leave it.
      expect(new URL(to, 'https://kinhin.dev').host, `${from} -> ${to}`).toBe('kinhin.dev')
      expect(to, from).toMatch(/^\/(?![/\\])/)
    }
    expect((await request.get('/v9.9.9//evil.example/x?a=1', { maxRedirects: 0 })).headers().location).toBe('/evil.example/x?a=1')
  })

  test('the redirect ends on a real page', async ({ request }) => {
    const res = await request.get('/v0.0.0-gone/guide/quick-start')
    expect(res.status()).toBe(200)
    expect(res.url()).toMatch(/\/guide\/quick-start$/)
  })

  test('ordinary paths that start with a v are not touched', async ({ request }) => {
    for (const p of ['/vercel.svg', '/videos/none.mp4']) expect([301, 302, 307, 308], p).not.toContain((await request.get(p, { maxRedirects: 0 })).status())
  })
})

test.describe('release snapshots (/<tag>/)', () => {
  const built = versions.filter(hasSnapshot)
  test.skip(built.length === 0, 'no snapshots in this build (needs the release tags: git fetch --tags)')

  for (const tag of built) {
    test(`${tag} renders its own docs under its base path`, async ({ page, problems, request }) => {
      await page.goto(`/${tag}/guide/quick-start`)
      await expect(page.locator('.version-banner')).toContainText(tag)
      await expect(page.locator('.version-banner').getByRole('link', { name: /Latest/ })).toHaveAttribute('href', 'https://kinhin.dev/')
      await expect(page.locator('h1')).toBeVisible()
      await hydrated(page)
      // Navigation stays inside the snapshot.
      await page.locator('aside.sidebar').first().getByRole('link').first().click()
      await expect(page).toHaveURL(new RegExp(`/${tag}/`))
      await expect(page.locator('details.version summary')).toHaveText(tag)
      expect(problems.filter((p) => !p.includes('launch'))).toEqual([])
      expect((await request.get(`/${tag}/guide/quick-start.md`)).status()).toBe(200)
      expect((await request.get(`/${tag}/llms.txt`)).status()).toBe(200)
    })

    test(`${tag} negotiates markdown and sends the security headers`, async ({ request }) => {
      const md = await request.get(`/${tag}/guide/quick-start`, { headers: { accept: 'text/markdown' } })
      expect(md.status()).toBe(200)
      expect(md.headers()['content-type']).toContain('text/markdown')
      expect((await md.text()).startsWith('# Quick start')).toBe(true)
      const home = await request.get(`/${tag}`, { headers: { accept: 'text/markdown' } })
      expect(home.headers()['content-type']).toContain('text/markdown')
      const html = await request.get(`/${tag}/guide/quick-start`)
      expect(html.headers()['content-type']).toContain('text/html')
      expect(html.headers()['x-content-type-options']).toBe('nosniff')
    })
  }
})
