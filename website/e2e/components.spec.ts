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

  test('arrow keys, Home and End move between the tabs (ARIA tabs pattern)', async ({ page }) => {
    await page.goto('/guide/quick-start')
    await hydrated(page)
    const human = tabs(page).getByRole('tab', { name: 'From the terminal' })
    const agent = tabs(page).getByRole('tab', { name: 'With an AI agent' })
    await expect(human).toHaveAttribute('tabindex', '0')
    await expect(agent).toHaveAttribute('tabindex', '-1')
    await human.focus()
    await page.keyboard.press('ArrowRight')
    await expect(agent).toBeFocused()
    await expect(agent).toHaveAttribute('aria-selected', 'true')
    await expect(tabs(page).locator('[data-which=agent]')).toBeVisible()
    await page.keyboard.press('Home')
    await expect(human).toBeFocused()
    await page.keyboard.press('End')
    await expect(agent).toBeFocused()
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
    // Until a diagram is near the viewport it is just its source text; scrolling to it loads Mermaid.
    await expect(page.locator('figure.mermaid-source pre').first()).toBeAttached()
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
    await expect(page.locator('figure.mermaid svg').first()).toBeVisible({ timeout: 20_000 })
    // Only diagrams near the viewport are rendered; the rest are still source text.
    expect(await page.locator('figure.mermaid-source').count()).toBeLessThan(await page.locator('figure.mermaid').count())
  })

  test('a diagram that fails to parse shows its error as text, never as markup', async ({ page }) => {
    // Mermaid's parse error quotes the diagram source. No docs page has a broken diagram, so patch the Mermaid component's
    // chunk to render a hostile one (the page's own data cannot be edited: its flight rows are length-prefixed).
    let patched = 0
    await page.route(/\/_next\/static\/.*\.js(\?.*)?$/, async (route) => {
      const res = await route.fetch()
      let body = await res.text()
      if (body.includes('mermaid-expand') && /\.render\([^,]+,\s*[\w$]+\)/.test(body)) {
        body = body.replace(/(\.render\([^,]+,)\s*[\w$]+\)/, '$1"notadiagram <img src=x onerror=window.__pwned=1>")')
        patched++
      }
      await route.fulfill({ response: res, body })
    })
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
    const err = page.getByTestId('mermaid-error').filter({ hasText: 'notadiagram' })
    await expect(err.first()).toBeVisible({ timeout: 20_000 })
    expect(patched, 'the Mermaid component chunk was patched (update the pattern if its minified shape changed)').toBeGreaterThan(0)
    await expect(page.locator('figure.mermaid img[src="x"]')).toHaveCount(0)
    expect(await page.evaluate(() => (window as unknown as { __pwned?: number }).__pwned)).toBeUndefined()
  })

  test('expand opens a viewer that zooms, pans and closes with Escape', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const fig = page.locator('figure.mermaid').first()
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
    await expect(fig.locator('svg')).toBeVisible({ timeout: 20_000 })
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
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

  test('the viewer has zoom buttons and keyboard shortcuts, and returns focus on close', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const fig = page.locator('figure.mermaid').first()
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
    await expect(fig.locator('svg')).toBeVisible({ timeout: 20_000 })
    const expand = fig.getByRole('button', { name: 'Expand' })
    await expand.click()
    const view = page.getByRole('dialog', { name: 'Diagram, enlarged' })
    await expect(view).toBeVisible()
    await expect(page.getByRole('button', { name: 'Close' })).toBeFocused()
    const stage = view.locator('.mermaid-stage')
    const transform = () => stage.evaluate((e) => (e as HTMLElement).style.transform)
    await view.getByRole('button', { name: 'Zoom in' }).click()
    await expect.poll(transform).toContain('scale(1.2)')
    await page.keyboard.press('-')
    await expect.poll(transform).toContain('scale(1)')
    await page.keyboard.press('+')
    await page.keyboard.press('+')
    await expect.poll(transform).not.toContain('scale(1)')
    await view.getByRole('button', { name: 'Reset zoom' }).click()
    await expect.poll(transform).toContain('scale(1)')
    await page.keyboard.press('Tab')
    await expect(page.getByRole('button', { name: 'Close' })).toBeFocused()
    await page.keyboard.press('Escape')
    await expect(view).toBeHidden()
    await expect(expand).toBeFocused()
  })

  test('the Close button also dismisses the viewer', async ({ page }) => {
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    const fig = page.locator('figure.mermaid').first()
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
    await expect(fig.locator('svg')).toBeVisible({ timeout: 20_000 })
    await fig.getByRole('button', { name: 'Expand' }).click()
    await page.getByRole('button', { name: 'Close' }).click()
    await expect(page.locator('.mermaid-view')).toHaveCount(0)
  })

  test('re-render in the other theme when the theme changes', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' })
    await page.goto('/' + mermaidRoute)
    await hydrated(page)
    await page.evaluate(() => document.querySelector('figure.mermaid')?.scrollIntoView({ block: 'center' }))
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
