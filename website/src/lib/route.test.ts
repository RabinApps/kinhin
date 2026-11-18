import assert from 'node:assert/strict'
import { test } from 'node:test'
import { isSnapshotPath, markdownRewrite, markdownUrl } from './route.ts'

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
