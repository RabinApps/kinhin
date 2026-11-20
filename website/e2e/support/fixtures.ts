import { expect, test as base, type Page } from '@playwright/test'

/**
 * Shared fixtures. Every test gets a page whose GitHub star request is mocked (the real API rate-limits CI), and
 * `problems`, the console errors, uncaught exceptions and failed same-origin requests seen so far.
 */
export const test = base.extend<{ problems: string[]; page: Page }>({
  problems: async ({}, use) => use([]),
  page: async ({ page, problems, baseURL }, use) => {
    await page.route('https://api.github.com/repos/RabinApps/kinhin', (r) =>
      r.fulfill({ json: { stargazers_count: 1234 }, headers: { 'access-control-allow-origin': '*' } }),
    )
    page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`))
    page.on('console', (m) => m.type() === 'error' && problems.push(`console: ${m.text()}`))
    page.on('response', (r) => {
      if (r.url().startsWith(baseURL ?? 'http://localhost') && r.status() >= 400) problems.push(`${r.status()} ${r.url()}`)
    })
    await use(page)
  },
})
export { expect }

/** Opens the search palette once the page has hydrated (clicking before hydration does nothing, so retry). */
export async function openSearch(page: Page): Promise<void> {
  const palette = page.getByRole('dialog', { name: 'Search' })
  await expect(async () => {
    if (!(await palette.isVisible())) await page.getByRole('button', { name: 'Search', exact: true }).click({ timeout: 1000 })
    await expect(palette).toBeVisible({ timeout: 1000 })
  }).toPass({ timeout: 10_000 })
}

/** Waits until React has attached handlers (the theme button works only after hydration). */
export async function hydrated(page: Page): Promise<void> {
  await page.waitForFunction(() => Object.keys(document.querySelector('header button.chip-btn') ?? {}).some((k) => k.startsWith('__react')))
}

/** Skip a describe block on the phone project (its layout is covered by theme-and-layout and search). */
export function desktopOnly(t: typeof test): void {
  t.beforeEach(({}, info) => t.skip(info.project.name !== 'desktop', 'desktop layout only'))
}
export function mobileOnly(t: typeof test): void {
  t.beforeEach(({}, info) => t.skip(info.project.name !== 'mobile', 'phone layout only'))
}
