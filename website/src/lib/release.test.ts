import assert from 'node:assert/strict'
import { test } from 'node:test'
import { releaseStage } from './release.ts'

test('a prerelease has a stage, a stable release has none', () => {
  assert.equal(releaseStage('0.0.1-beta-7'), 'BETA')
  assert.equal(releaseStage('0.2.0-alpha.1'), 'ALPHA')
  assert.equal(releaseStage('1.0.0-rc.2'), 'RC')
  assert.equal(releaseStage('0.1.0'), null)
  assert.equal(releaseStage('1.2.3'), null)
})
