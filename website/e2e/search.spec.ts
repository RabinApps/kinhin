import { expect, hydrated, openSearch, test } from './support/fixtures'
import { pageOf, pages } from './support/site'

const palette = (page: import('@playwright/test').Page) => page.getByRole('dialog', { name: 'Search' })

test.describe('search palette', () => {
  test('opens from the header button and focuses the input', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await expect(palette(page).getByPlaceholder('Search the docs')).toBeFocused()
    await expect(palette(page)).toContainText('copy as markdown')
  })

  test('Ctrl+K toggles it', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'no keyboard on a phone')
    await page.goto('/guide/quick-start')
    await openSearch(page)
    await page.keyboard.press('Escape')
    await expect(palette(page)).toBeHidden()
    await page.keyboard.press('Control+k')
    await expect(palette(page)).toBeVisible()
    await page.keyboard.press('Control+k')
    await expect(palette(page)).toBeHidden()
  })

  test('finds a page by title, with the page first', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await palette(page).getByRole('combobox').fill(pageOf('guide/runtimes').title)
    const first = palette(page).locator('.palette-list li button').first()
    await expect(first.locator('strong')).toHaveText(pageOf('guide/runtimes').title)
  })

  test('finds a page by a heading inside it', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    const target = pages.find((p) => p.route === 'guide/scaling')!
    const heading = target.headings.find((h) => h.depth === 2 && h.text.length > 8)!
    await palette(page).getByRole('combobox').fill(heading.text)
    await expect(palette(page).locator('.palette-list strong', { hasText: target.title })).toBeVisible()
  })

  test('forgives a typo', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await palette(page).getByRole('combobox').fill('runtims')
    await expect(palette(page).locator('.palette-list strong', { hasText: pageOf('guide/runtimes').title })).toBeVisible()
  })

  test('shows at most eight hits and says when there are none', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    const box = palette(page).getByRole('combobox')
    await box.fill('runner')
    await expect(palette(page).locator('.palette-list li button').first()).toBeVisible()
    expect(await palette(page).locator('.palette-list li button').count()).toBeLessThanOrEqual(8)
    await box.fill('zzzzqqqq')
    await expect(palette(page).locator('.palette-empty')).toHaveText('No results for “zzzzqqqq”')
  })

  test('arrow keys move the selection and Enter opens the page', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard navigation')
    await page.goto('/')
    await openSearch(page)
    await palette(page).getByRole('combobox').fill('install')
    const hits = palette(page).locator('.palette-list li button')
    await expect(hits.first()).toHaveClass(/on/)
    await page.keyboard.press('ArrowDown')
    await expect(hits.nth(1)).toHaveClass(/on/)
    await page.keyboard.press('ArrowUp')
    await expect(hits.first()).toHaveClass(/on/)
    const title = (await hits.first().locator('strong').textContent())!
    await page.keyboard.press('Enter')
    await expect(palette(page)).toBeHidden()
    await expect(page.locator('h1')).toHaveText(title)
  })

  test('clicking a hit opens it', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await palette(page).getByRole('combobox').fill('quick start')
    const hit = palette(page).locator('.palette-list li button', { hasText: pageOf('guide/quick-start').title }).first()
    await hit.click()
    await expect(page).toHaveURL(/\/guide\/quick-start$/)
  })

  test('Ctrl+Enter copies the selected page as markdown', async ({ page, request }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard shortcut')
    await page.goto('/')
    await openSearch(page)
    await palette(page).getByRole('combobox').fill(pageOf('guide/quick-start').title)
    await expect(palette(page).locator('.palette-list li button').first().locator('strong')).toHaveText(pageOf('guide/quick-start').title)
    await page.keyboard.press('Control+Enter')
    const expected = await (await request.get('/guide/quick-start.md')).text()
    await expect.poll(() => page.evaluate(() => navigator.clipboard.readText())).toBe(expected)
  })

  test('Escape and a click outside close it', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await page.keyboard.press('Escape')
    await expect(palette(page)).toBeHidden()
    await openSearch(page)
    await page.mouse.click(4, 4)
    await expect(palette(page)).toBeHidden()
  })

  test('the index is fetched only when the palette is first opened', async ({ page }) => {
    const seen: string[] = []
    page.on('request', (r) => r.url().includes('search-index.json') && seen.push(r.url()))
    await page.goto('/')
    await page.waitForLoadState('networkidle')
    expect(seen).toEqual([])
    await openSearch(page)
    await expect.poll(() => seen.length).toBe(1)
  })

  test('follows the ARIA combobox pattern and keeps focus inside', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard navigation')
    await page.goto('/')
    const opener = page.getByRole('button', { name: 'Search', exact: true })
    await openSearch(page)
    const box = palette(page).getByRole('combobox')
    await expect(box).toHaveAttribute('aria-expanded', 'false')
    await box.fill('runtimes')
    await expect(box).toHaveAttribute('aria-expanded', 'true')
    const options = palette(page).getByRole('option')
    await expect(options.first()).toHaveAttribute('aria-selected', 'true')
    await expect(box).toHaveAttribute('aria-activedescendant', 'palette-opt-0')
    await page.keyboard.press('ArrowDown')
    await expect(box).toHaveAttribute('aria-activedescendant', 'palette-opt-1')
    await expect(options.nth(1)).toHaveAttribute('aria-selected', 'true')
    await expect(options.first()).toHaveAttribute('aria-selected', 'false')
    // Tab does not leave the palette.
    await page.keyboard.press('Tab')
    await expect(box).toBeFocused()
    // Closing returns focus to the button that opened it.
    await page.keyboard.press('Escape')
    await expect(palette(page)).toBeHidden()
    await expect(opener).toBeFocused()
  })

  test('a shortcut pressed twice while the palette loads never reaches the browser, and ends with the palette open', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard shortcut')
    await page.goto('/')
    await hydrated(page)
    const prevented = await page.evaluate(() =>
      [0, 1].map(() => {
        const e = new KeyboardEvent('keydown', { key: 'k', ctrlKey: true, cancelable: true, bubbles: true })
        window.dispatchEvent(e)
        return e.defaultPrevented
      }),
    )
    expect(prevented).toEqual([true, true])
    await expect(palette(page)).toBeVisible()
  })
})
