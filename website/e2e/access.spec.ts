import { expect, request as pwRequest, test } from '@playwright/test'

/**
 * The dev environment (dev.kinhin.dev) sits behind Cloudflare Access. Run against it with a service token:
 *   E2E_BASE_URL=https://dev.kinhin.dev E2E_EXPECT_ACCESS=1 CF_ACCESS_CLIENT_ID=… CF_ACCESS_CLIENT_SECRET=… npm run e2e -- access
 * Skipped everywhere else (the local Worker and production are public).
 */
test.skip(!process.env.E2E_EXPECT_ACCESS, 'only for the Access-protected dev environment')

test.describe('dev environment behind Cloudflare Access', () => {
  test('an anonymous request is not served the site', async ({ baseURL }) => {
    const anon = await pwRequest.newContext({ baseURL, extraHTTPHeaders: {} })
    for (const path of ['/', '/guide/quick-start', '/llms.txt', '/sitemap.xml']) {
      const res = await anon.get(path, { maxRedirects: 0 })
      expect([302, 401, 403], `${path} must go to the Access login or be refused, got ${res.status()}`).toContain(res.status())
      if (res.status() === 302) expect(res.headers().location ?? '').toContain('cloudflareaccess.com')
    }
    await anon.dispose()
  })

  test('with the service token the site is served, and tells crawlers to stay away (pages)', async ({ request }) => {
    const res = await request.get('/guide/quick-start')
    expect(res.status()).toBe(200)
    expect(res.headers()['x-robots-tag']).toContain('noindex')
  })
})
