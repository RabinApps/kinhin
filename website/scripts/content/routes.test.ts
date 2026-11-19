import assert from 'node:assert/strict'
import { test } from 'node:test'
import { routeFor } from './routes.ts'

test('routes mirror the old VitePress rewrites', () => {
  assert.equal(routeFor('website/index.md'), '')
  assert.equal(routeFor('website/blog/index.md'), 'blog')
  assert.equal(routeFor('website/blog/beta-2.md'), 'blog/beta-2')
  assert.equal(routeFor('website/cli/commands.md'), 'cli/commands')
  assert.equal(routeFor('website/search/how-many-macos-vms-can-run-at-once.md'), 'how-many-macos-vms-can-run-at-once')
  assert.equal(routeFor('docs/why.md'), 'guide/why-kinhin')
  assert.equal(routeFor('docs/forges.md'), 'guide/forges')
  assert.equal(routeFor('docs/forges/README.md'), 'guide/forges/overview')
  assert.equal(routeFor('docs/forges/gitlab.md'), 'guide/forges/gitlab')
  assert.equal(routeFor('docs/scaling.md'), 'guide/scaling')
})

test('unpublished and unrelated files have no route', () => {
  assert.equal(routeFor('docs/app.md'), undefined)
  assert.equal(routeFor('docs/adding-a-forge.md'), undefined)
  assert.equal(routeFor('docs/plans/x.md'), undefined)
  assert.equal(routeFor('README.md'), undefined)
  assert.equal(routeFor('docs/telemetry/x.md'), undefined)
})
