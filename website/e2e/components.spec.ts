import { expect, hydrated, test } from './support/fixtures'
import { mermaidRoute, pageOf } from './support/site'

test.describe('audience tabs (guide/quick-start)', () => {
  const tabs = (page: import('@playwright/test').Page) => page.locator('.tabs')

  test('both panels are in the HTML and the terminal one shows first', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(tabs(page).getByRole('tabpanel', { includeHidden: true })).toHaveCount(2)
    await expect(tabs(page).getByRole('tab', { name: 'From the terminal' })).toHaveAttribute('aria-selected', 'true')
    await expect(tabs(page).locator('[data-which=human]')).toBeVisible()
    await expect(tabs(page).locator('[data-which=agent]')).toBeHidden()
  })

  test('switching tabs swaps the panels and remembers the choice', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    await tabs(page).getByRole('tab', { name: 'With an AI agent' }).click()
    await expect(tabs(page).locator('[data-which=agent]')).toBeVisible()
    await expect(tabs(page).locator('[data-which=human]')).toBeHidden()
    expect(await page.evaluate(() => localStorage.getItem('kinhin:audience'))).toBe('agent')
    await page.reload()
    await expect(tabs(page).getByRole('tab', { name: 'With an AI agent' })).toHaveAttribute('aria-selected', 'true')
    await tabs(page).getByRole('tab', { name: 'From the terminal' }).click()
    await expect(tabs(page).locator('[data-which=human]')).toBeVisible()
  })

  test('#with-an-ai-agent opens the agent tab', async ({ page }) => {
    await page.addInitScript(() => localStorage.removeItem('kinhin:audience'))
    await page.goto('/guide/quick-start#with-an-ai-agent')
    await expect(tabs(page).getByRole('tab', { name: 'With an AI agent' })).toHaveAttribute('aria-selected', 'true')
    await expect(tabs(page).locator('[data-which=agent]')).toBeVisible()
  })

  test('callouts inside a panel keep their title and style', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.locator('aside.callout-warning .callout-title').first()).toHaveText('Beta')
    await expect(tabs(page).locator('aside.callout-tip .callout-title').first()).toBeAttached()
  })
})

test.describe('content rendering', () => {
  test('tables scroll inside a wrapper instead of widening the page', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const wrap = page.locator('.table-wrap').first()
    await expect(wrap.locator('table')).toBeVisible()
    expect(await wrap.evaluate((e) => getComputedStyle(e).overflowX)).toBe('auto')
  })

  test('relative images from docs/ load', async ({ page }) => {
    await page.goto('/guide/video-gallery')
    const imgs = page.locator('.prose img')
    const n = await imgs.count()
    expect(n).toBeGreaterThan(0)
    for (let i = 0; i < n; i++) {
      await imgs.nth(i).scrollIntoViewIfNeeded()
      await expect.poll(() => imgs.nth(i).evaluate((e: HTMLImageElement) => e.complete && e.naturalWidth), `image ${i}`).toBeGreaterThan(0)
    }
  })

  test('internal links in rendered docs are client-side links to real pages', async ({ page, request }) => {
    await page.goto('/guide/quick-start')
    const href = await page.locator('.prose a[href^="/guide/"]').first().getAttribute('href')
    expect(href).toBeTruthy()
    expect((await request.get(href!)).status()).toBe(200)
  })

  test('external links are plain links', async ({ page }) => {
    await page.goto('/guide/quick-start')
    const ext = page.locator('.prose a[href^="https://"]').first()
    await expect(ext).toHaveAttribute('rel', /noopener/)
  })

  test('inline code and headings render', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await expect(page.locator('.prose h2').first()).toBeVisible()
    await expect(page.locator('.prose code').first()).toBeVisible()
    await expect(page.locator('.prose h2').nth(0)).toHaveAttribute('id', /.+/)
  })
})

test.describe('Mermaid diagrams', () => {
  test.skip(!mermaidRoute, 'no page with a diagram')

  test('render lazily to an SVG', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await expect(page.locator('figure.mermaid svg').first()).toBeVisible({ timeout: 20_000 })
    await expect(page.locator('figure.mermaid pre')).toHaveCount(0)
  })

  test('expand opens a viewer that zooms, pans and closes with Escape', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const fig = page.locator('figure.mermaid').first()
    await expect(fig.locator('svg')).toBeVisible({ timeout: 20_000 })
    await fig.scrollIntoViewIfNeeded()
    await fig.getByRole('button', { name: 'Expand' }).click()
    const view = page.getByRole('dialog').filter({ has: page.locator('.mermaid-stage') })
    await expect(view).toBeVisible()
    const stage = view.locator('.mermaid-stage')
    const transform = () => stage.evaluate((e) => (e as HTMLElement).style.transform)
    expect(await transform()).toContain('scale(1)')
    await view.hover()
    await page.mouse.wheel(0, -300)
    await expect.poll(transform).not.toContain('scale(1)')
    const box = (await stage.boundingBox())!
    const before = await transform()
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
    await page.mouse.down()
    await page.mouse.move(box.x + box.width / 2 + 80, box.y + box.height / 2 + 40, { steps: 4 })
    await page.mouse.up()
    await expect.poll(transform).not.toBe(before)
    await page.keyboard.press('Escape')
    await expect(view).toBeHidden()
  })

  test('the Close button also dismisses the viewer', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const fig = page.locator('figure.mermaid').first()
    await expect(fig.locator('svg')).toBeVisible({ timeout: 20_000 })
    await fig.getByRole('button', { name: 'Expand' }).click()
    await page.getByRole('button', { name: 'Close' }).click()
    await expect(page.locator('.mermaid-view')).toHaveCount(0)
  })

  test('re-render in the other theme when the theme changes', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const svg = page.locator('figure.mermaid svg').first()
    await expect(svg).toBeVisible({ timeout: 20_000 })
    const before = await svg.getAttribute('id')
    await page.getByRole('button', { name: 'Toggle light and dark theme' }).click()
    await expect.poll(async () => page.locator('figure.mermaid svg').first().getAttribute('id'), { timeout: 20_000 }).not.toBe(before)
  })

  test('the architecture page keeps its title', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await expect(page.locator('h1')).toHaveText(pageOf(mermaidRoute!).title)
  })
})
