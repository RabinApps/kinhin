import { expect, hydrated, mobileOnly, test } from './support/fixtures'

/** Phone project only (touch, coarse pointer, no hover). */
mobileOnly(test)

test.describe('touch', () => {
  test('the code copy button is visible without hovering and big enough to tap', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const copy = page.locator('.code-copy').first()
    await copy.scrollIntoViewIfNeeded()
    expect(await copy.evaluate((e) => getComputedStyle(e).opacity)).toBe('1')
    expect((await copy.boundingBox())!.height).toBeGreaterThanOrEqual(34)
  })

  test('header controls and menu links are at least 44px tall', async ({ page }) => {
    await page.goto('/')
    await hydrated(page)
    for (const name of ['Menu', 'Search']) {
      const box = (await page.getByRole('button', { name, exact: true }).boundingBox())!
      expect(box.height, name).toBeGreaterThanOrEqual(44)
    }
    await page.getByRole('button', { name: 'Menu' }).click()
    for (const link of await page.getByRole('navigation', { name: 'Main' }).getByRole('link').all()) expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(40)
  })

  test('docs bar, sidebar links, pager and page actions are comfortable targets', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    await page.locator('button.docs-bar').click()
    for (const link of (await page.locator('aside.sidebar li a').all()).slice(0, 5)) expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(40)
    await page.getByRole('button', { name: 'Close documentation navigation' }).click()
    for (const b of await page.locator('.page-actions .chip-btn').all()) expect((await b.boundingBox())!.height).toBeGreaterThanOrEqual(44)
  })

  test('the search palette fits the screen with the keyboard-sized viewport', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 420 }) // roughly a phone with its keyboard open
    await page.goto('/')
    await hydrated(page)
    await page.getByRole('button', { name: 'Search', exact: true }).click()
    await page.getByRole('combobox').fill('runtimes')
    const box = (await page.getByRole('dialog', { name: 'Search' }).boundingBox())!
    expect(box.y).toBeGreaterThanOrEqual(0)
    expect(box.y + box.height).toBeLessThanOrEqual(420)
  })
})
