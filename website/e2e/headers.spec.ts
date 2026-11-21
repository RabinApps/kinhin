import { expect, test } from '@playwright/test'

/** Security headers on pages (set by src/middleware.ts) and on static files (public/_headers). */
const expectSecure = (h: Record<string, string>, where: string) => {
  expect(h['strict-transport-security'], where).toMatch(/^max-age=\d{8,}\b/)
  expect(h['x-content-type-options'], where).toBe('nosniff')
  expect(h['referrer-policy'], where).toBe('strict-origin-when-cross-origin')
  expect(h['permissions-policy'], where).toContain('camera=()')
  expect(h['x-frame-options'], where).toBe('DENY')
  expect(h['cross-origin-opener-policy'], where).toBe('same-origin')
  expect(h['x-permitted-cross-domain-policies'], where).toBe('none')
  const csp = h['content-security-policy'] ?? ''
  for (const d of ["default-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "base-uri 'self'"]) expect(csp, `${where}: ${d}`).toContain(d)
  expect(csp, `${where}: images are same-origin only (no third-party tracking pixels)`).toMatch(/img-src 'self' data:(;|$)/)
  expect(csp, `${where}: the page makes no third-party calls`).toMatch(/connect-src 'self'(;|$)/)
  expect(csp, where).not.toContain('github.com')
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

  test('security.txt is published with a contact, a policy and an expiry', async ({ request }) => {
    const res = await request.get('/.well-known/security.txt')
    expect(res.status()).toBe(200)
    expect(res.headers()['content-type']).toMatch(/^text\/plain/)
    const body = await res.text()
    expect(body).toMatch(/^Contact: mailto:security@rabinapps\.com$/m)
    expect(body).toMatch(/^Policy: https:\/\/github\.com\/RabinApps\/kinhin\/blob\/main\/SECURITY\.md$/m)
    expect(body).toMatch(/^Canonical: https:\/\/kinhin\.dev\/\.well-known\/security\.txt$/m)
    // Only that it is a valid date: asserting it is still in the future would break CI on the day it lapses.
    expect(Date.parse(/^Expires: (.+)$/m.exec(body)?.[1] ?? ''), 'Expires must be an ISO date').not.toBeNaN()
  })

  test('HSTS is also sent on responses the Worker builds itself (markdown, llms.txt, feed, sitemap)', async ({ request }) => {
    for (const path of ['/guide/quick-start.md', '/llms.txt', '/blog/feed.xml', '/sitemap.xml', '/search-index.json']) {
      expect((await request.get(path)).headers()['strict-transport-security'], path).toMatch(/^max-age=\d{8,}\b/)
    }
    const md = await request.get('/guide/quick-start', { headers: { accept: 'text/markdown' } })
    expect(md.headers()['strict-transport-security'], 'Accept: text/markdown').toMatch(/^max-age=\d{8,}\b/)
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

test.describe('privacy', () => {
  test('a page load makes no request to any other origin', async ({ page, baseURL }) => {
    const foreign: string[] = []
    page.on('request', (r) => {
      const u = new URL(r.url())
      if (!r.url().startsWith(baseURL!) && u.protocol.startsWith('http')) foreign.push(r.url())
    })
    for (const path of ['/', '/guide/quick-start', '/guide/architecture']) {
      await page.goto(path)
      await page.waitForLoadState('networkidle')
    }
    expect(foreign).toEqual([])
  })
})
