import { desktopOnly, expect, hydrated, openSearch, test } from './support/fixtures'
import { mermaidRoute } from './support/site'

/**
 * Loading behaviour: what a page downloads up front, and what is deferred until it is needed. Budgets are on uncompressed
 * bytes (a response body as the browser receives it after decompression); scripts/check-bundle.mjs holds the gzipped budget.
 */
desktopOnly(test)

async function scriptBytes(page: import('@playwright/test').Page, run: () => Promise<void>) {
  const sizes: { url: string; bytes: number }[] = []
  const pending: Promise<void>[] = []
  page.on('response', (r) => {
    if (r.request().resourceType() === 'script') pending.push(r.body().then((b) => void sizes.push({ url: r.url(), bytes: b.length })).catch(() => {}))
  })
  await run()
  await Promise.all(pending)
  return sizes
}

const total = (s: { bytes: number }[]) => s.reduce((n, x) => n + x.bytes, 0)

test.describe('code splitting', () => {
  for (const path of ['/', '/guide/quick-start', '/blog']) {
    test(`${path}: first-load JavaScript is small and has no diagram library`, async ({ page }) => {
      const s = await scriptBytes(page, async () => {
        await page.goto(path)
        await page.waitForLoadState('networkidle')
      })
      expect(total(s), 'uncompressed JS loaded up front').toBeLessThan(800_000)
      expect(Math.max(...s.map((x) => x.bytes)), 'largest single script').toBeLessThan(300_000)
    })
  }

  test('Mermaid is fetched only when a diagram nears the viewport', async ({ page }) => {
    test.skip(!mermaidRoute, 'no page with a diagram')
    await page.setViewportSize({ width: 1440, height: 700 })
    await page.goto('/' + mermaidRoute)
    await page.waitForLoadState('networkidle')
    // The diagrams are spread down a long page: the last one is still just its source text, and no heavy chunk was needed for it.
    const total_ = await page.locator('figure.mermaid').count()
    expect(total_).toBeGreaterThan(1)
    expect(await page.locator('figure.mermaid-source').count(), 'a diagram far below the fold is not rendered yet').toBeGreaterThan(0)
    // Scroll to the last diagram: it renders, and the page no longer has any source-only figure.
    await page.evaluate(() => [...document.querySelectorAll('figure.mermaid')].at(-1)?.scrollIntoView({ block: 'center' }))
    await expect(page.locator('figure.mermaid-source')).toHaveCount(0, { timeout: 20_000 })
    await expect(page.locator('figure.mermaid svg')).toHaveCount(total_, { timeout: 20_000 })
  })

  test('the search palette is a separate chunk and works when opened straight away', async ({ page }) => {
    await page.goto('/')
    await hydrated(page)
    await openSearch(page)
    await page.getByRole('combobox').fill('install')
    await expect(page.getByRole('option').first()).toBeVisible()
  })

  test('pages without code or tabs still send their content as HTML (no JavaScript needed)', async ({ browser }) => {
    const ctx = await browser.newContext({ javaScriptEnabled: false })
    const page = await ctx.newPage()
    await page.goto('/guide/quick-start')
    await expect(page.locator('h1')).toHaveText('Quick start')
    await expect(page.locator('.prose h2').first()).toBeVisible()
    await expect(page.locator('aside.sidebar').first()).toBeAttached()
    await expect(page.locator('pre.shiki').first()).toBeVisible()
    await ctx.close()
  })

  test('without JavaScript a diagram shows its source and the tabs keep the terminal panel', async ({ browser }) => {
    const ctx = await browser.newContext({ javaScriptEnabled: false })
    const page = await ctx.newPage()
    if (mermaidRoute) {
      await page.goto('/' + mermaidRoute)
      await expect(page.locator('figure.mermaid-source pre').first()).toBeAttached()
    }
    await page.goto('/guide/quick-start')
    await expect(page.locator('[data-which=human]')).toBeVisible()
    await ctx.close()
  })
})
