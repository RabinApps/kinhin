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
