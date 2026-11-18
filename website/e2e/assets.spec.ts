import { expect, test } from '@playwright/test'
import { hasPublic } from './support/site'

test.describe('static files', () => {
  for (const [path, type] of [
    ['/favicon.svg', 'image/svg+xml'],
    ['/favicon-32.png', 'image/png'],
    ['/apple-touch-icon.png', 'image/png'],
    ['/og.png', 'image/png'],
    ['/logo.png', 'image/png'],
    ['/mark.svg', 'image/svg+xml'],
  ] as const) {
    test(`${path} is served as ${type}`, async ({ request }) => {
      const res = await request.get(path)
      expect(res.status()).toBe(200)
      expect(res.headers()['content-type']).toContain(type)
    })
  }

  test('the launch video files are served as video', async ({ request }) => {
    test.skip(!hasPublic('launch.mp4'), 'no launch video in this checkout')
    expect((await request.head('/launch.mp4')).headers()['content-type']).toContain('video/mp4')
    expect((await request.head('/launch.webm')).headers()['content-type']).toContain('video/webm')
    expect((await request.get('/launch-poster.png')).status()).toBe(200)
  })

  test('the Sparkle update feed is served when the build has one', async ({ request }) => {
    test.skip(!hasPublic('appcast.xml'), 'no appcast.xml (it is fetched from the latest release by CI)')
    const res = await request.get('/appcast.xml')
    expect(res.status()).toBe(200)
    expect(res.headers()['content-type']).toMatch(/xml/)
    expect(await res.text()).toContain('<rss')
  })
})
