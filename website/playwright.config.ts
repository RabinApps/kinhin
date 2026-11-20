import { defineConfig, devices } from '@playwright/test'

/**
 * End-to-end tests of the built site as users and agents meet it: the OpenNext Worker served by `wrangler dev`, so the
 * middleware, the static-assets cache and the generated files are the real ones.
 *
 *   scripts/build-site.sh          build once (website/.open-next)
 *   npm run e2e                    run everything (starts the Worker unless E2E_BASE_URL is set)
 *   E2E_BASE_URL=https://… npm run e2e     test an already running or deployed site
 *
 * CHROMIUM_PATH points at a preinstalled Chromium when `playwright install` is not available (the cloud sandbox).
 */
const external = process.env.E2E_BASE_URL
const port = Number(process.env.PORT ?? 8788)
const baseURL = external ?? `http://localhost:${port}`
const executablePath = process.env.CHROMIUM_PATH
// Behind Cloudflare Access (dev.kinhin.dev) a service token lets the tests in: E2E_BASE_URL=https://dev.kinhin.dev E2E_EXPECT_ACCESS=1 …
const access = process.env.CF_ACCESS_CLIENT_ID && process.env.CF_ACCESS_CLIENT_SECRET
  ? { 'CF-Access-Client-Id': process.env.CF_ACCESS_CLIENT_ID, 'CF-Access-Client-Secret': process.env.CF_ACCESS_CLIENT_SECRET }
  : undefined

const use = {
  baseURL,
  ...(access ? { extraHTTPHeaders: access } : {}),
  trace: 'on-first-retry' as const,
  launchOptions: executablePath ? { executablePath, args: ['--no-sandbox'] } : {},
  contextOptions: { permissions: ['clipboard-read', 'clipboard-write'] },
}

export default defineConfig({
  testDir: './e2e',
  outputDir: './.e2e-results',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never', outputFolder: 'playwright-report' }]] : [['list']],
  timeout: 30_000,
  expect: { timeout: 7_000, toHaveScreenshot: { maxDiffPixelRatio: 0.01 } },
  snapshotPathTemplate: '{testDir}/__screenshots__/{projectName}/{testFilePath}/{arg}{ext}',
  // The visual comparisons are opt-in (`npm run e2e -- --grep @visual`): baselines are platform specific.
  grepInvert: process.env.E2E_VISUAL ? undefined : /@visual/,
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], ...use, viewport: { width: 1440, height: 900 } } },
    {
      name: 'mobile',
      // Chromium with a phone viewport and touch; WebKit is not installed everywhere this runs.
      use: { ...devices['Pixel 7'], ...use, contextOptions: { permissions: ['clipboard-read', 'clipboard-write'] } },
      testIgnore: ['**/markdown-agents.spec.ts', '**/links.spec.ts', '**/appcast.spec.ts', '**/versions.spec.ts'],
    },
  ],
  webServer: external
    ? undefined
    : {
        command: `npx opennextjs-cloudflare populateCache local && npx wrangler dev --local --port ${port}`,
        url: `${baseURL}/`,
        // A server may already be up on the port: scripts/smoke.sh in the same CI job, or `wrangler dev` in another terminal. Reuse it
        // (Playwright waits for `/`, runs, and leaves it running); otherwise it starts the Worker itself, as above.
        reuseExistingServer: true,
        timeout: 180_000,
        stdout: 'ignore',
        stderr: 'ignore',
      },
})
