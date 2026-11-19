import { desktopOnly, expect, test } from './support/fixtures'
import { hasPublic, latestPostRoute, manifest, releaseVersion, stage } from './support/site'

const { hero, features, install, questions } = manifest.home
const latestPost = '/' + latestPostRoute

test.describe('home page', () => {
  test('the hero comes from website/index.md', async ({ page }) => {
    await page.goto('/')
    const h1 = page.locator('h1')
    await expect(h1).toContainText(hero.text.replace(/\s+/g, ' ').split('. ')[0])
    const last = hero.text.split(/(?<=\.)\s+/).pop()!
    await expect(h1.locator('.accent')).toHaveText(last)
    await expect(page.locator('.hero .lead')).toHaveText(hero.tagline)
  })

  test('the call-to-action buttons go where index.md says', async ({ page }) => {
    await page.goto('/')
    for (const a of hero.actions) {
      await expect(page.locator('.hero .cta').getByRole('link', { name: a.text, exact: true })).toHaveAttribute('href', a.link)
    }
    await page.locator('.hero .cta').getByRole('link', { name: hero.actions[0].text }).click()
    await expect(page).toHaveURL(new RegExp(`${hero.actions[0].link}$`))
    await expect(page.locator('h1')).toBeVisible()
  })

  test('the terminal shows the install commands', async ({ page }) => {
    await page.goto('/')
    const term = page.locator('.hero .terminal')
    for (const line of install) await expect(term).toContainText(line)
    await expect(term).toContainText('fleet online')
  })

  test('the beta banner names the current release and links to the newest post', async ({ page, request }) => {
    await page.goto('/')
    const warn = page.locator('aside.callout-warning')
    await expect(warn.locator('.callout-title')).toHaveText(stage ? `${stage[0]}${stage.slice(1).toLowerCase()} (v${releaseVersion})` : `v${releaseVersion}`)
    const post = warn.getByRole('link', { name: stage ? `${stage.toLowerCase()} announcement` : 'release announcement' })
    await expect(post).toHaveAttribute('href', latestPost)
    expect((await request.get(latestPost)).status()).toBe(200)
    await expect(page.locator('aside.callout-tip')).toContainText('donate or sponsor')
  })

  test('the launch video appears only when the file is there', async ({ page }) => {
    await page.goto('/')
    const section = page.locator('section[aria-labelledby=video-h]')
    if (!hasPublic('launch.mp4')) {
      await expect(section).toHaveCount(0)
      return
    }
    await expect(section).toBeVisible()
    const video = section.locator('video')
    await expect(video).toHaveAttribute('poster', '/launch-poster.png')
    await expect(video).toHaveAttribute('loop', '')
    await expect(video.locator('source[type="video/webm"]')).toHaveAttribute('src', '/launch.webm')
    await expect(video.locator('source[type="video/mp4"]')).toHaveAttribute('src', '/launch.mp4')
    // Only one clip is shown, so there are no tabs.
    await expect(section.getByRole('tab')).toHaveCount(0)
    await expect.poll(() => video.evaluate((v: HTMLVideoElement) => ({ err: v.error?.code ?? 0, net: v.networkState })), { timeout: 15_000 }).toMatchObject({ err: 0 })
  })

  test('the fleet diagram and the agents section are present', async ({ page }) => {
    await page.goto('/')
    for (const node of ['FORGES', 'KINHIN', 'JOBS']) await expect(page.locator('.fleet-node h3', { hasText: node })).toBeVisible()
    await expect(page.locator('section.agents')).toContainText('Every page is also markdown.')
    await expect(page.locator('section.agents').getByRole('link', { name: 'llms.txt' })).toHaveAttribute('href', '/llms.txt')
  })

  test('every feature card links to a real page', async ({ page, request }) => {
    await page.goto('/')
    for (const f of features) {
      const card = page.locator('a.feature', { hasText: f.title })
      await expect(card).toBeVisible()
      await expect(card).toHaveAttribute('href', f.link)
      await expect(card).toContainText(f.details)
      expect((await request.get(f.link)).status(), f.link).toBe(200)
    }
  })

  test('the common questions list every search-intent page', async ({ page, request }) => {
    await page.goto('/')
    expect(questions.length).toBeGreaterThan(0)
    for (const q of questions) {
      await expect(page.locator('.faq h3', { hasText: q.group })).toBeVisible()
      for (const l of q.links) {
        await expect(page.locator('.faq').getByRole('link', { name: l.text, exact: true })).toHaveAttribute('href', l.href)
        expect((await request.get(l.href)).status(), l.href).toBe(200)
      }
    }
  })

  test('the header and footer links work', async ({ page }) => {
    await page.goto('/')
    await expect(page.locator('footer')).toContainText('Apache License 2.0')
    for (const [name, href] of [['Support kinhin', '/guide/support'], ['Who uses kinhin', '/guide/used-by'], ['llms.txt', '/llms.txt']]) {
      await expect(page.locator('footer').getByRole('link', { name })).toHaveAttribute('href', href)
    }
    await expect(page.locator('footer').getByRole('link', { name: 'SupDesk' })).toHaveAttribute('href', 'https://supdesk.app/en')
    // On a phone the link lives in the menu.
    if (page.viewportSize()!.width <= 900) await page.getByRole('button', { name: 'Menu' }).click()
    await expect(page.getByRole('link', { name: 'Download' })).toHaveAttribute('href', '/guide/install')
    // The badge follows the version: BETA for a prerelease, nothing once a stable release ships.
    if (stage) await expect(page.locator('header .brand .badge')).toHaveText(stage)
    else await expect(page.locator('.brand .badge')).toHaveCount(0)
    // The section links sit next to the logo, and there is no CLI entry.
    const links = page.getByRole('navigation', { name: 'Main' }).getByRole('link')
    if (page.viewportSize()!.width > 900) {
      await expect(links).toHaveText(['Guide', 'Blog', 'Docs'])
      const brand = (await page.locator('header .brand').boundingBox())!
      const guide = (await links.first().boundingBox())!
      expect(guide.x).toBeGreaterThan(brand.x + brand.width)
      expect(guide.x).toBeLessThan(brand.x + brand.width + 120)
    }
  })

  test('the star chip shows the count read at build time, or a plain GitHub label', async ({ page }, info) => {
    test.skip(info.project.name === 'mobile', 'the star chip is not in the phone header')
    await page.goto('/')
    const chip = page.getByRole('link', { name: /stars on GitHub/ })
    const { stars } = manifest
    await expect(chip).toContainText(stars === null ? 'GitHub' : stars >= 1000 ? `${(stars / 1000).toFixed(1)}k` : String(stars))
    await expect(chip).toHaveAttribute('href', 'https://github.com/RabinApps/kinhin')
  })
})
