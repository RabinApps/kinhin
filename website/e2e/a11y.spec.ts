import AxeBuilder from '@axe-core/playwright'
import { desktopOnly, expect, hydrated, openSearch, test } from './support/fixtures'
import { latestPostRoute } from './support/site'

/**
 * Automated accessibility checks (axe): no serious or critical violations on the pages people land on, in both
 * colour schemes. Exceptions are listed here with the reason, never silently skipped.
 */
const EXCEPTIONS: Record<string, string> = {}
const latestPost = latestPostRoute

async function audit(page: import('@playwright/test').Page, label: string) {
  const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze()
  const bad = results.violations.filter((v) => ['serious', 'critical'].includes(v.impact ?? '') && !(v.id in EXCEPTIONS))
  expect(bad.map((v) => `${v.id}: ${v.help} (${v.nodes.length}) e.g. ${v.nodes[0]?.html.slice(0, 120)}`), label).toEqual([])
}

desktopOnly(test)

for (const scheme of ['dark', 'light'] as const) {
  test.describe(`axe, ${scheme}`, () => {
    test.beforeEach(async ({ page }) => page.emulateMedia({ colorScheme: scheme }))

    for (const [name, url] of [
      ['home', '/'],
      ['a docs page', '/guide/quick-start'],
      ['the CLI page', '/cli/commands'],
      ['the blog index', '/blog'],
      ['a blog post', `/${latestPost}`],
      ['a search-intent page', '/how-many-macos-vms-can-run-at-once'],
      ['a page with tables and callouts', '/guide/runtimes'],
      ['a page with a diagram', '/guide/architecture'],
      ['a forge page with long code', '/guide/forges/github'],
      ['a long reference page', '/guide/config'],
    ] as const) {
      test(name, async ({ page }) => {
        await page.goto(url)
        await hydrated(page)
        await audit(page, `${name} (${scheme})`)
      })
    }

    test('the 404 page', async ({ page }) => {
      await page.goto('/no-such-page')
      await audit(page, `404 (${scheme})`)
    })

    test('the version picker, open', async ({ page }) => {
      await page.goto('/')
      await hydrated(page)
      await page.locator('details.version summary').click()
      await audit(page, `version picker (${scheme})`)
    })

    test('a phone-width docs page with its menu open', async ({ page }) => {
      await page.setViewportSize({ width: 360, height: 740 })
      await page.goto('/guide/quick-start')
      await hydrated(page)
      await page.getByRole('button', { name: 'Menu' }).click()
      await audit(page, `phone menu (${scheme})`)
    })

    test('the search palette', async ({ page }) => {
      await page.goto('/')
      await openSearch(page)
      await page.getByRole('combobox').fill('runtimes')
      await expect(page.locator('.palette-list li button').first()).toBeVisible()
      await audit(page, `search (${scheme})`)
    })
  })
}

test.describe('structure', () => {
  test('landmarks, one h1, language and no empty links or buttons', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.locator('html')).toHaveAttribute('lang', 'en')
    await expect(page.getByRole('banner')).toHaveCount(1)
    await expect(page.getByRole('main')).toHaveCount(1)
    await expect(page.getByRole('contentinfo')).toHaveCount(1)
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible()
    await expect(page.getByRole('navigation', { name: 'On this page' })).toBeVisible()
    await expect(page.getByRole('navigation', { name: 'Previous and next page' })).toBeVisible()
    await expect(page.locator('h1')).toHaveCount(1)
    const unnamed = await page.evaluate(() =>
      [...document.querySelectorAll('a, button')].filter((e) => !(e.getAttribute('aria-label') || e.textContent?.trim() || e.querySelector('img[alt]'))).map((e) => e.outerHTML.slice(0, 100)),
    )
    expect(unnamed).toEqual([])
  })

  test('the search dialog is modal and labelled', async ({ page }) => {
    await page.goto('/')
    await openSearch(page)
    await expect(page.getByRole('dialog', { name: 'Search' })).toHaveAttribute('aria-modal', 'true')
  })

  test('a page with reduced motion keeps the diagram still', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' })
    await page.goto('/')
    const anim = await page.locator('.wire i').first().evaluate((e) => getComputedStyle(e).animationName)
    expect(anim).toBe('none')
  })
})
