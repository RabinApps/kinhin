import assert from 'node:assert/strict'
import { test } from 'node:test'
import { isSafePath, isSnapshotPath, markdownRewrite, markdownUrl, removedSnapshotRedirect } from './route.ts'

const versions = ['v0.0.1-beta-7', 'v0.0.1-beta-6']

test('the latest docs rewrite to the markdown route handler', () => {
  assert.equal(markdownRewrite('/', versions), '/md/index')
  assert.equal(markdownRewrite('/guide/quick-start', versions), '/md/guide/quick-start')
  assert.equal(markdownRewrite('/guide/quick-start/', versions), '/md/guide/quick-start')
})

test('a release snapshot rewrites to its static .md copy', () => {
  assert.equal(markdownRewrite('/v0.0.1-beta-6', versions), '/v0.0.1-beta-6/index.md')
  assert.equal(markdownRewrite('/v0.0.1-beta-6/', versions), '/v0.0.1-beta-6/index.md')
  assert.equal(markdownRewrite('/v0.0.1-beta-6/guide/quick-start', versions), '/v0.0.1-beta-6/guide/quick-start.md')
})

test('a path that merely starts like a tag is not a snapshot', () => {
  assert.equal(markdownRewrite('/v0.0.1-beta-66/guide/x', versions), '/md/v0.0.1-beta-66/guide/x')
})

test('the advertised .md URL', () => {
  assert.equal(markdownUrl('/guide/quick-start', versions), '/guide/quick-start.md')
  assert.equal(markdownUrl('/', versions), '/index.md')
  assert.equal(markdownUrl('/v0.0.1-beta-6/guide/quick-start', versions), '/v0.0.1-beta-6/guide/quick-start.md')
})

test('which paths belong to a snapshot', () => {
  assert.equal(isSnapshotPath('/v0.0.1-beta-6', versions), true)
  assert.equal(isSnapshotPath('/v0.0.1-beta-6/guide/x', versions), true)
  assert.equal(isSnapshotPath('/guide/quick-start', versions), false)
  assert.equal(isSnapshotPath('/v0.0.1-beta-66/x', versions), false)
})

test('only plain paths are advertised in headers', () => {
  for (const ok of ['/', '/guide/quick-start', '/v0.0.1-beta-6/guide/x', '/how-to-run-github-actions-on-a-self-hosted-mac']) assert.equal(isSafePath(ok), true, ok)
  for (const bad of ['/a>; rel="x"', '/a b', '/a"b', '/../etc/passwd', '/a\r\nSet-Cookie: x=1', '/a<b', '/a;b', 'guide/x']) assert.equal(isSafePath(bad), false, JSON.stringify(bad))
})

test('a removed release snapshot redirects to the same page on the latest site', () => {
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-1/guide/quick-start', versions), '/guide/quick-start')
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-1/', versions), '/')
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-1', versions), '/')
  assert.equal(removedSnapshotRedirect('/v0.1.0/guide/x/', versions), '/guide/x')
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-1/blog/beta-2.md', versions), '/blog/beta-2.md')
})

test('a removed snapshot never redirects off-site (no protocol-relative Location)', () => {
  for (const p of ['/v9.9.9//evil.com', '/v9.9.9//evil.com/x', '/v9.9.9///evil.com', '/v9.9.9/\\evil.com', '/v9.9.9/\\/evil.com', '/v9.9.9/\\\\evil.com/', '/v9.9.9/ /evil.com']) {
    const to = removedSnapshotRedirect(p, versions)
    assert.ok(to !== null && /^\/(?![/\\])/.test(to), `${JSON.stringify(p)} -> ${JSON.stringify(to)}`)
  }
  assert.equal(removedSnapshotRedirect('/v9.9.9//evil.com/x', versions), '/evil.com/x')
})

test('listed versions and ordinary paths are left alone', () => {
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-7/guide/x', versions), null)
  assert.equal(removedSnapshotRedirect('/v0.0.1-beta-6', versions), null)
  for (const p of ['/', '/guide/quick-start', '/videos/launch.mp4', '/vercel.svg', '/v1/guide']) assert.equal(removedSnapshotRedirect(p, versions), null, p)
})
