import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { cleanSitePath, internalLinks, mapLinks, resolveDocsLink, rewriteHref, type LinkContext } from './links.ts'

/** A throwaway checkout holding `files`, plus the route the build gives docs/why.md. */
function fixture(t: { after: (fn: () => void) => void }, files: string[]): LinkContext {
  const root = mkdtempSync(path.join(tmpdir(), 'kinhin-links-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  for (const file of files) {
    mkdirSync(path.dirname(path.join(root, file)), { recursive: true })
    writeFileSync(path.join(root, file), '')
  }
  return { root, routes: new Map([['docs/why.md', 'guide/why-kinhin']]), ref: 'main', origin: 'https://kinhin.dev' }
}

test('a docs/ link to a published page becomes its site route, anchor kept', (t) => {
  const ctx = fixture(t, ['docs/why.md'])
  assert.deepEqual(resolveDocsLink('why.md#why-kinhin', 'docs/scaling.md', ctx), { href: '/guide/why-kinhin#why-kinhin', missing: false })
  assert.equal(rewriteHref('why.md', 'docs/scaling.md', ctx), '/guide/why-kinhin')
})

test('a query string is not part of the file lookup and survives the rewrite', (t) => {
  const ctx = fixture(t, ['docs/why.md'])
  assert.deepEqual(resolveDocsLink('why.md?plain=1', 'docs/scaling.md', ctx), {
    href: '/guide/why-kinhin?plain=1',
    missing: false,
  })
  assert.deepEqual(resolveDocsLink('why.md?plain=1#why-kinhin', 'docs/scaling.md', ctx), {
    href: '/guide/why-kinhin?plain=1#why-kinhin',
    missing: false,
  })
})

test('a percent-encoded path resolves to the file it names; a malformed escape does not throw', (t) => {
  const ctx = fixture(t, ['docs/why.md', 'docs/adding-a-forge.md'])
  assert.deepEqual(resolveDocsLink('why%2Emd', 'docs/scaling.md', ctx), { href: '/guide/why-kinhin', missing: false })
  assert.equal(
    rewriteHref('adding%2Da-forge.md#step-1', 'docs/why.md', ctx),
    'https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md#step-1',
  )
  assert.equal(resolveDocsLink('why%ZZ.md', 'docs/scaling.md', ctx).missing, true)
  // One malformed segment does not stop the others decoding.
  const mixed = fixture(t, ['docs/my folder/100%.md'])
  assert.equal(resolveDocsLink('my%20folder/100%.md', 'docs/why.md', mixed).missing, false)
})

test('a docs/ link to the README becomes the home page, suffix kept', (t) => {
  const ctx = fixture(t, ['README.md'])
  assert.equal(rewriteHref('../README.md', 'docs/why.md', ctx), '/')
  assert.equal(rewriteHref('../README.md#install', 'docs/why.md', ctx), '/#install')
  assert.equal(rewriteHref('../README.md?plain=1#install', 'docs/why.md', ctx), '/?plain=1#install')
})

test('a query-only link stays on the page it is written in', (t) => {
  const ctx = fixture(t, ['docs/why.md'])
  assert.deepEqual(resolveDocsLink('?plain=1#why-kinhin', 'docs/why.md', ctx), {
    href: '?plain=1#why-kinhin',
    missing: false,
  })
})

test('a docs/ link to a file with no page goes to GitHub, anchored to this ref', (t) => {
  const ctx = fixture(t, ['docs/adding-a-forge.md'])
  assert.equal(
    rewriteHref('adding-a-forge.md#step-1', 'docs/why.md', ctx),
    'https://github.com/RabinApps/kinhin/blob/main/docs/adding-a-forge.md#step-1',
  )
})

test('a docs/ link to a file that is not in the checkout is reported, not passed through silently', (t) => {
  const ctx = fixture(t, [])
  assert.deepEqual(resolveDocsLink('../gone.md#x', 'docs/forges/github.md', ctx), { href: '../gone.md#x', missing: true })
  assert.equal(resolveDocsLink('why.md', 'docs/why.md', ctx).missing, true, 'the page itself is missing from this fixture')
})

test('links outside docs/ and already-resolved links are left alone', (t) => {
  const ctx = fixture(t, ['website/index.md'])
  for (const href of ['https://example.com/x', '#anchor', 'mailto:a@b', '//cdn.example/x', '/guide/why-kinhin']) {
    assert.deepEqual(resolveDocsLink(href, 'docs/why.md', ctx), { href, missing: false })
  }
  assert.deepEqual(resolveDocsLink('./missing.md', 'website/blog/beta-2.md', ctx), { href: './missing.md', missing: false })
})

test('site paths lose the .html VitePress emitted and trailing slashes', () => {
  assert.equal(cleanSitePath('/guide/quick-start.html'), '/guide/quick-start')
  assert.equal(cleanSitePath('/guide/quick-start/'), '/guide/quick-start')
  assert.equal(cleanSitePath('/guide/index'), '/guide')
  assert.equal(cleanSitePath('/'), '/')
  assert.equal(cleanSitePath(''), '/')
})

test('fenced code keeps its links; images go through the image mapper', () => {
  const md = ['```md', '[not a link](/keep.html)', '```', '', '[page](/guide/x.html) ![shot](shot.png)'].join('\n')
  const out = mapLinks(md, cleanSitePath, (href) => `/_docs/${href}`)
  assert.match(out, /\[not a link\]\(\/keep\.html\)/)
  assert.match(out, /\[page\]\(\/guide\/x\)/)
  assert.match(out, /!\[shot\]\(\/_docs\/shot\.png\)/)
})

test('a link shown in inline code is an example, not a link the page has', () => {
  const md = 'Show `[example](missing.md)` then [page](/guide/x.html).'
  assert.equal(mapLinks(md, cleanSitePath), 'Show `[example](missing.md)` then [page](/guide/x).')
  assert.deepEqual(internalLinks('`[a](/guide/x)` [b](/guide/y)'), ['/guide/y'])
  // An escaped backtick is literal, so the link between the two stays a link.
  assert.equal(mapLinks('a \\` b [page](/guide/x.html) c \\`', cleanSitePath), 'a \\` b [page](/guide/x) c \\`')
})

test('an image whose alt text holds inline code is still one image', () => {
  const md = '![`cli`](shot.png) and `![x](y.png)`'
  assert.equal(mapLinks(md, (h) => `link:${h}`, (h) => `img:${h}`), '![`cli`](img:shot.png) and `![x](y.png)`')
})

test('a target inside a code span is left alone, even when the span starts inside an image alt', () => {
  const md = '![`x](y.png)`](shot.png)'
  assert.equal(mapLinks(md, (h) => h, (h) => `img:${h}`), md)
})

test('a code span in a quote survives its marked continuation lines', () => {
  const md = '> `example\n> [page](/guide/x.html)`'
  assert.equal(mapLinks(md, (h) => `fn:${h}`), md)
})

test('internalLinks keeps only site-absolute targets', () => {
  assert.deepEqual(internalLinks('[a](/guide/x) [b](https://example.com) [c](#top) [d](/guide/y#z)'), ['/guide/x', '/guide/y#z'])
})
