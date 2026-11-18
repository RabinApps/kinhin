import { expect, hydrated, openSearch, test } from './support/fixtures'

/**
 * Screenshot comparisons, opt-in: `E2E_VISUAL=1 npm run e2e -- visual` (baselines: `npm run e2e:update`).
 * Baselines depend on fonts and the OS, so they are generated on the CI image, not committed from a laptop.
 * Compare by eye against design/exports/site/*.png when changing the look.
 */
for (const scheme of ['dark', 'light'] as const) {
  test.describe(`@visual ${scheme}`, () => {
    test.use({ colorScheme: scheme })

    const shot = async (page: import('@playwright/test').Page, name: string) =>
      expect(page).toHaveScreenshot(`${name}-${scheme}.png`, {
        fullPage: false,
        animations: 'disabled',
        mask: [page.locator('video'), page.getByRole('link', { name: /stars on GitHub/ })],
      })

    test('home', async ({ page }) => {
      await page.goto('/')
      await hydrated(page)
      await shot(page, 'home')
    })
    test('docs page', async ({ page }) => {
      await page.goto('/guide/quick-start')
      await hydrated(page)
      await shot(page, 'docs')
    })
    test('search palette', async ({ page }) => {
      await page.goto('/guide/quick-start')
      await openSearch(page)
      await page.getByRole('combobox').fill('runtimes')
      await expect(page.locator('.palette-list li button').first()).toBeVisible()
      await shot(page, 'palette')
    })
    test('404', async ({ page }) => {
      await page.goto('/no-such-page')
      await shot(page, 'not-found')
    })
  })
}
