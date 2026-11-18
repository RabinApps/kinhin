import { expect, test } from '@playwright/test'

/** Security headers on pages (set by src/middleware.ts) and on static files (public/_headers). */
const expectSecure = (h: Record<string, string>, where: string) => {
  expect(h['x-content-type-options'], where).toBe('nosniff')
  expect(h['referrer-policy'], where).toBe('strict-origin-when-cross-origin')
  expect(h['permissions-policy'], where).toContain('camera=()')
  expect(h['x-frame-options'], where).toBe('DENY')
  const csp = h['content-security-policy'] ?? ''
  for (const d of ["default-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "base-uri 'self'"]) expect(csp, `${where}: ${d}`).toContain(d)
  expect(csp, where).toContain('connect-src \'self\' https://api.github.com')
}

test.describe('security headers', () => {
  for (const path of ['/', '/guide/quick-start', '/cli/commands', '/blog', '/no-such-page']) {
    test(`${path} (a page served by the Worker)`, async ({ request }) => {
      expectSecure((await request.get(path)).headers(), path)
    })
  }

  test('static files carry them too', async ({ request }) => {
    for (const path of ['/og.png', '/logo.png', '/favicon.svg']) expectSecure((await request.get(path)).headers(), path)
  })

  test('the markdown copies are served with nosniff', async ({ request }) => {
    const res = await request.get('/guide/quick-start.md')
    expect(res.headers()['x-content-type-options']).toBe('nosniff')
  })

  test('the content security policy does not break the site (no violations on the main pages)', async ({ page }) => {
    const violations: string[] = []
    page.on('console', (m) => /content security policy|Refused to/i.test(m.text()) && violations.push(m.text()))
    for (const path of ['/', '/guide/quick-start', '/guide/architecture']) {
      await page.goto(path)
      await page.waitForLoadState('networkidle')
    }
    // Mermaid and the search palette exercise dynamic code paths.
    await page.getByRole('button', { name: 'Search', exact: true }).click()
    await page.waitForTimeout(500)
    expect(violations).toEqual([])
  })
})
