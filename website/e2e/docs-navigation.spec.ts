import { desktopOnly, expect, hydrated, mobileOnly, test } from './support/fixtures'
import { docRoutes, pageOf, sidebar, sidebarLinks } from './support/site'

const published = new Set(docRoutes)
const readable = sidebarLinks.filter((l) => published.has(l.link.slice(1)))

test.describe('docs navigation (desktop)', () => {
  desktopOnly(test)

  test('the sidebar shows every group and marks the current page', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const side = page.locator('aside.sidebar').first()
    for (const g of sidebar) await expect(side.locator('.side-h', { hasText: g.text }).first()).toBeAttached()
    const current = side.locator('a[aria-current=page]')
    await expect(current).toHaveCount(1)
    await expect(current).toHaveText('Quick start')
    await expect(current).toHaveAttribute('href', '/guide/quick-start')
  })

  test('collapsed groups open only when they hold the current page', async ({ page }) => {
    const group = (name: string) => page.locator('aside.sidebar').first().locator('details', { has: page.locator('summary.side-h', { hasText: name }) })
    await page.goto('/guide/quick-start')
    await expect(group('Contributing')).not.toHaveAttribute('open', '')
    await expect(group('Product videos')).not.toHaveAttribute('open', '')
    await page.goto('/guide/e2e-testing')
    await expect(group('Contributing')).toHaveAttribute('open', '')
    await page.goto('/guide/forges/github')
    const forgeNotes = page.locator('aside.sidebar').first().locator('details.side-sub', { hasText: 'Forge API notes' })
    await expect(forgeNotes).toHaveAttribute('open', '')
    await expect(forgeNotes.locator('a[aria-current=page]')).toHaveText('GitHub')
  })

  test('clicking a sidebar link navigates without a full reload', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await page.evaluate(() => ((window as unknown as { __marker: number }).__marker = 1))
    await page.locator('aside.sidebar').first().getByRole('link', { name: 'Why kinhin' }).click()
    await expect(page).toHaveURL(/\/guide\/why-kinhin$/)
    await expect(page.locator('h1')).toHaveText(pageOf('guide/why-kinhin').title)
    expect(await page.evaluate(() => (window as unknown as { __marker?: number }).__marker)).toBe(1)
  })

  test('the header marks the section you are in', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Guide' })).toHaveAttribute('aria-current', 'page')
    await page.goto('/blog')
    await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Blog' })).toHaveAttribute('aria-current', 'page')
    // The CLI reference is reached from the sidebar and search, not the header.
    await expect(page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'CLI' })).toHaveCount(0)
  })

  test('the pager walks the sidebar in order', async ({ page }) => {
    test.setTimeout(120_000)
    for (let i = 0; i < readable.length; i++) {
      await page.goto(readable[i].link)
      const prev = page.locator('nav.pager a:not(.next)')
      const next = page.locator('nav.pager a.next')
      const flat = sidebarLinks.findIndex((l) => l.link === readable[i].link)
      if (flat > 0) await expect(prev).toHaveAttribute('href', sidebarLinks[flat - 1].link)
      else await expect(prev).toHaveCount(0)
      if (flat < sidebarLinks.length - 1) await expect(next).toHaveAttribute('href', sidebarLinks[flat + 1].link)
      else await expect(next).toHaveCount(0)
    }
  })

  test('the table of contents lists the headings and follows the scroll', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const toc = page.locator('nav.toc')
    const heads = pageOf('guide/quick-start').headings
    await expect(toc).toBeVisible()
    await expect(toc.locator('a')).toHaveCount(heads.length)
    for (const h of heads.slice(0, 3)) await expect(toc.locator(`a[href="#${h.id}"]`)).toHaveText(h.text)
    const target = heads.filter((h) => h.depth === 2).at(-1)!
    await toc.locator(`a[href="#${target.id}"]`).click()
    await expect(page).toHaveURL(new RegExp(`#${target.id}$`))
    await expect(page.locator(`#${target.id}`)).toBeInViewport()
    await expect(toc.locator('a[aria-current=true]')).toHaveText(target.text)
  })

  test('the page header has a breadcrumb, markdown actions and an edit link', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.getByRole('navigation', { name: 'Breadcrumb' })).toHaveText('GUIDE / GET STARTED')
    await expect(page.getByRole('link', { name: 'Edit on GitHub' })).toHaveAttribute('href', `https://github.com/RabinApps/kinhin/blob/main/${pageOf('guide/quick-start').src}`)
    await expect(page.getByRole('link', { name: 'View .md' })).toHaveAttribute('href', '/guide/quick-start.md')
  })

  test('section headings link to themselves', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const h = pageOf('guide/quick-start').headings[0]
    const heading = page.locator(`#${h.id}`)
    await heading.hover()
    await expect(heading.locator('a.anchor')).toHaveAttribute('href', `#${h.id}`)
  })

  test('blog and search-intent pages have no sidebar', async ({ page }) => {
    for (const route of ['/blog', '/how-many-macos-vms-can-run-at-once']) {
      await page.goto(route)
      await expect(page.locator('aside.sidebar')).toHaveCount(0)
      await expect(page.locator('.plain-shell')).toBeVisible()
    }
  })
})

test.describe('docs navigation (phone)', () => {
  mobileOnly(test)

  test('the sidebar sits behind the docs bar', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    const bar = page.locator('button.docs-bar')
    const side = page.locator('aside.sidebar')
    await expect(bar).toContainText(pageOf('guide/quick-start').title)
    await expect(bar).toHaveAttribute('aria-expanded', 'false')
    await expect(side).toBeHidden()
    await bar.click()
    await expect(bar).toHaveAttribute('aria-expanded', 'true')
    await expect(side).toBeVisible()
    await side.getByRole('link', { name: 'Install & updates' }).click()
    await expect(page).toHaveURL(/\/guide\/install$/)
    // Choosing a page closes the menu again.
    await expect(bar).toHaveAttribute('aria-expanded', 'false')
    await expect(side).toBeHidden()
    await expect(page.locator('aside.sidebar[data-open]')).toHaveCount(0)
  })

  test('the keyboard stays in the drawer and comes back to the bar', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    const bar = page.locator('button.docs-bar')
    const close = page.getByRole('button', { name: 'Close documentation navigation' })
    // Focus is read from the document rather than with the `:focus` selector, which also depends on the tab itself having
    // the keyboard focus in the browser.
    const drawerHasFocus = () =>
      page.evaluate(() => !!document.querySelector('aside.sidebar')?.contains(document.activeElement))
    await bar.click()
    // Opening moves the keyboard into the drawer…
    await expect.poll(drawerHasFocus).toBe(true)
    // …Tab from the bar cannot reach the page behind the scrim, it lands on the drawer's close button…
    await bar.focus()
    await page.keyboard.press('Tab')
    await expect(close).toBeFocused()
    // …and Escape closes the drawer and hands the keyboard back to the bar.
    await page.keyboard.press('Escape')
    await expect(bar).toHaveAttribute('aria-expanded', 'false')
    await expect(bar).toBeFocused()
  })
})
