import { expect, hydrated, mobileOnly, test } from './support/fixtures'
import { pages } from './support/site'

const latestPost = pages.map((p) => p.route).filter((r) => /^blog\/beta-\d+$/.test(r)).sort().at(-1) ?? 'blog'
const SAMPLE = ['', 'guide/quick-start', 'cli/commands', latestPost, 'guide/architecture', 'how-to-run-github-actions-on-a-self-hosted-mac']

test.describe('theme', () => {
  test('follows the system colour scheme until you choose', async ({ page }) => {
    const bg = () => page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--bg').trim())
    await page.emulateMedia({ colorScheme: 'dark' })
    await page.goto('/')
    expect(await bg()).toBe('#05060a')
    await page.emulateMedia({ colorScheme: 'light' })
    await page.goto('/')
    expect(await bg()).toBe('#f6f7fb')
  })

  test('the toggle flips and remembers the theme across a reload, before first paint', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await page.goto('/')
    await hydrated(page)
    const html = page.locator('html')
    await page.getByRole('button', { name: 'Toggle light and dark theme' }).click()
    await expect(html).toHaveAttribute('data-theme', 'light')
    expect(await page.evaluate(() => localStorage.getItem('kinhin:theme'))).toBe('light')
    await page.reload({ waitUntil: 'domcontentloaded' })
    // The inline script in <head> applies it before the page is hydrated.
    expect(await html.getAttribute('data-theme')).toBe('light')
    await hydrated(page)
    await page.getByRole('button', { name: 'Toggle light and dark theme' }).click()
    await expect(html).toHaveAttribute('data-theme', 'dark')
    expect(await page.evaluate(() => getComputedStyle(document.body).backgroundColor)).toBe('rgb(5, 6, 10)')
  })

  test('both themes keep text readable (body vs background)', async ({ page }) => {
    for (const scheme of ['dark', 'light'] as const) {
      await page.emulateMedia({ colorScheme: scheme })
      await page.goto('/guide/quick-start')
      const [fg, bg] = await page.evaluate(() => [getComputedStyle(document.querySelector('.prose p')!).color, getComputedStyle(document.body).backgroundColor])
      expect(fg, scheme).not.toBe(bg)
    }
  })
})

test.describe('responsive layout', () => {
  for (const width of [390, 768, 1440]) {
    for (const route of SAMPLE) {
      test(`no horizontal overflow at ${width}px on ${route || 'home'}`, async ({ page }, info) => {
        test.skip(info.project.name === 'mobile' && width !== 390, 'the phone project covers 390px')
        await page.setViewportSize({ width, height: 900 })
        await page.goto('/' + route)
        await page.waitForLoadState('networkidle')
        const [scroll, inner] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth])
        expect(scroll).toBeLessThanOrEqual(inner)
      })
    }
  }
})

test.describe('phone menu', () => {
  mobileOnly(test)

  test('the hamburger opens the main navigation and closes after a click', async ({ page }) => {
    await page.goto('/')
    await hydrated(page)
    const menu = page.getByRole('button', { name: 'Menu' })
    const nav = page.getByRole('navigation', { name: 'Main' })
    await expect(menu).toHaveAttribute('aria-expanded', 'false')
    await expect(nav).toBeHidden()
    await menu.click()
    await expect(menu).toHaveAttribute('aria-expanded', 'true')
    await expect(nav).toBeVisible()
    await nav.getByRole('link', { name: 'Blog' }).click()
    await expect(page).toHaveURL(/\/blog$/)
    await expect(menu).toHaveAttribute('aria-expanded', 'false')
  })

  test('the hero fits the screen without clipping the headline', async ({ page }) => {
    await page.goto('/')
    const box = (await page.locator('.hero h1').boundingBox())!
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(page.viewportSize()!.width)
  })
})

test.describe('keyboard', () => {
  test('the skip link is the first stop and jumps to the content', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard only')
    await page.goto('/guide/quick-start')
    await hydrated(page)
    await page.keyboard.press('Tab')
    const skip = page.getByRole('link', { name: 'Skip to content' })
    await expect(skip).toBeFocused()
    await page.keyboard.press('Enter')
    await expect(page).toHaveURL(/#main$/)
  })

  test('tabbing reaches the brand, the navigation and the search button', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'keyboard only')
    await page.goto('/')
    await hydrated(page)
    const seen: string[] = []
    for (let i = 0; i < 14; i++) {
      await page.keyboard.press('Tab')
      seen.push(await page.evaluate(() => (document.activeElement as HTMLElement | null)?.getAttribute('aria-label') ?? (document.activeElement as HTMLElement | null)?.textContent?.trim().slice(0, 30) ?? ''))
    }
    expect(seen.join('|')).toContain('Search')
    expect(seen.join('|')).toContain('Guide')
    expect(seen.join('|')).toContain('kinhin')
  })
})
