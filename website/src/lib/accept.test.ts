import assert from 'node:assert/strict'
import { test } from 'node:test'
import { prefersMarkdown } from './accept.ts'

test('browsers keep HTML', () => {
  assert.equal(prefersMarkdown('text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,*/*;q=0.8'), false)
  assert.equal(prefersMarkdown('*/*'), false)
  assert.equal(prefersMarkdown(null), false)
})
test('agents asking for markdown get it', () => {
  assert.equal(prefersMarkdown('text/markdown'), true)
  assert.equal(prefersMarkdown('text/markdown, text/html;q=0.8'), true)
  assert.equal(prefersMarkdown('text/markdown;q=1.0, */*;q=0.1'), true)
})
test('HTML wins on a higher q, or a tie where it is listed first', () => {
  assert.equal(prefersMarkdown('text/html, text/markdown;q=0.5'), false)
  assert.equal(prefersMarkdown('text/html, text/markdown'), false)
  assert.equal(prefersMarkdown('text/markdown;q=0'), false)
})
