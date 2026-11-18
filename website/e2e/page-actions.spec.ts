import { expect, hydrated, test } from './support/fixtures'
import { pageOf } from './support/site'

test.describe('page actions and code blocks', () => {
  test('Copy as Markdown puts the page’s markdown on the clipboard', async ({ page, request }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    const button = page.getByRole('button', { name: 'Copy as Markdown' })
    await button.click()
    await expect(page.getByRole('button', { name: 'Copied' })).toBeVisible()
    const expected = await (await request.get('/guide/quick-start.md')).text()
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(expected)
    // The label goes back by itself.
    await expect(page.getByRole('button', { name: 'Copy as Markdown' })).toBeVisible({ timeout: 5000 })
  })

  test('View .md opens the markdown copy', async ({ page, request }) => {
    await page.goto('/guide/quick-start')
    const link = page.getByRole('link', { name: 'View .md' })
    await expect(link).toHaveAttribute('href', '/guide/quick-start.md')
    const res = await request.get('/guide/quick-start.md')
    expect(res.headers()['content-type']).toContain('text/markdown')
    const [resp] = await Promise.all([page.waitForResponse((r) => r.url().endsWith('/guide/quick-start.md')), link.click()])
    expect(resp.status()).toBe(200)
  })

  test('the home page has no page actions (it is not a doc)', async ({ page }) => {
    await page.goto('/')
    await expect(page.locator('.page-actions')).toHaveCount(0)
  })

  test('a code block copies exactly its text', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    const block = page.locator('.code').first()
    await block.scrollIntoViewIfNeeded()
    await block.hover()
    const expected = await block.locator('pre').innerText()
    await block.getByRole('button', { name: 'Copy code' }).click()
    await expect(block.getByRole('button', { name: 'Copy code' })).toHaveText('copied')
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(expected)
    await expect(block.getByRole('button', { name: 'Copy code' })).toHaveText('copy', { timeout: 5000 })
  })

  test('code is highlighted for light and dark', async ({ page }) => {
    await page.goto('/guide/quick-start')
    // Tokens carry a short class (the colour pairs live in one generated stylesheet), not an inline style each.
    const span = page.locator('pre.shiki span[class^="t"]').first()
    await expect(span).toBeAttached()
    expect(await span.getAttribute('style')).toBeNull()
    expect(await span.evaluate((e) => getComputedStyle(e).color)).not.toBe(await page.locator('pre.shiki').first().evaluate((e) => getComputedStyle(e).backgroundColor))
  })

  test('the markdown actions exist on every doc kind', async ({ page }) => {
    for (const route of ['guide/quick-start', 'cli/commands', pageOf('guide/architecture').route]) {
      await page.goto('/' + route)
      await expect(page.locator('.page-actions').getByRole('link', { name: 'View .md' })).toHaveAttribute('href', `/${route}.md`)
    }
  })
})
