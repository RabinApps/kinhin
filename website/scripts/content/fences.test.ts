import assert from 'node:assert/strict'
import { test } from 'node:test'
import { codeSpans, outsideFences, stripVue } from './fences.ts'

const upper = (chunk: string): string => chunk.toUpperCase()

test('a longer fence can contain a shorter one', () => {
  const md = ['a', '````md', '```', 'b', '```', 'c', '````', 'd'].join('\n')
  assert.equal(outsideFences(md, upper), ['A', '````md', '```', 'b', '```', 'c', '````', 'D'].join('\n'))
})

test('a closing fence needs the same character and no suffix', () => {
  const md = ['```', '~~~', '``` x', 'inner', '```', 'out'].join('\n')
  assert.equal(outsideFences(md, upper), ['```', '~~~', '``` x', 'inner', '```', 'OUT'].join('\n'))
})

test('fences inside blockquotes and lists are respected', () => {
  const quoted = ['> ```html', '> <script>alert(1)</script>', '> ```'].join('\n')
  assert.equal(stripVue(quoted), quoted)
  const listed = ['- item', '  ```html', '  <style>a{}</style>', '  ```'].join('\n')
  assert.equal(stripVue(listed), listed)
})

test('a fence opened on the list-item line is respected', () => {
  const bullet = ['- ```html', '  <script>alert(1)</script>', '  ```', 'after'].join('\n')
  assert.equal(stripVue(bullet), bullet)
  const numbered = ['1. ```html', '   <style>a{}</style>', '   ```'].join('\n')
  assert.equal(stripVue(numbered), numbered)
})

test('fences nested in any mix of quotes and list items are respected', () => {
  for (const prefix of ['- > ', '> - ', '> > ', '1. - ', '> 1. > ']) {
    const pad = ' '.repeat(prefix.length)
    const md = [`${prefix}\`\`\`html`, `${pad}<script>alert(1)</script>`, `${pad}\`\`\``].join('\n')
    assert.equal(stripVue(md), md, prefix)
  }
})

/** The text each span holds, without its backticks. */
const spanText = (text: string): string[] => codeSpans(text).map((s) => text.slice(s.from, s.to))

test('a code span runs from a backtick run to the next run of the same length', () => {
  assert.deepEqual(spanText('before `[x](y.md)` after'), ['`[x](y.md)`'])
  assert.deepEqual(spanText('a ``b `c` d`` e'), ['``b `c` d``'])
  assert.deepEqual(spanText('a `b\nc` d'), ['`b\nc`'], 'a span can span lines')
})

test('an unpaired or escaped backtick opens nothing', () => {
  assert.deepEqual(spanText('a lone ` tick at the end'), [])
  assert.deepEqual(spanText('a \\` b `c` d'), ['`c`'])
  // A span closes in its own block: the stray run above does not swallow the next one.
  assert.deepEqual(spanText('a ` b\n\nc `d` e'), ['`d`'])
})

test('backticks in different list items or blocks do not pair', () => {
  const items = ['- `', '- [page](/guide/x.html)', '- `', '', '# `', '> `'].join('\n')
  assert.deepEqual(spanText(items), [])
  assert.deepEqual(spanText('- one `a`\n- two `b`'), ['`a`', '`b`'])
})

test('a block keeps its paragraph across marked continuation lines', () => {
  // A quote paragraph continues on the next quoted line, and a list item on its indented continuation.
  assert.deepEqual(spanText('> `example\n> [page](/guide/x.html)`'), ['`example\n> [page](/guide/x.html)`'])
  assert.deepEqual(spanText('- `a\n  b`'), ['`a\n  b`'])
})

test('an ATX heading ends before the paragraph under it, so their backticks do not pair', () => {
  assert.deepEqual(spanText('# `heading\n[page](/guide/x.html)`'), [])
})

test('stripVue removes script/style blocks outside fences only', () => {
  const md = ['<script setup>\nconst a = 1\n</script>', '', '# T', '', '```html', '<script>x</script>', '```', '<style>a{}</style>', 'end'].join('\n')
  const out = stripVue(md)
  assert.ok(!out.includes('const a'))
  assert.ok(!out.includes('a{}'))
  assert.ok(out.includes('<script>x</script>'))
  assert.ok(out.includes('end'))
})

test('stripVue also removes upper-case tags and ones a first pass would reassemble', () => {
  assert.equal(stripVue('<SCRIPT>a</SCRIPT>keep'), 'keep')
  assert.equal(stripVue('<STYLE>a{}</Style >keep'), 'keep')
  // A browser ends the element at `</script` plus anything up to `>`, so an end tag can carry junk.
  assert.equal(stripVue('<script>a</script\t\n bar>keep'), 'keep')
  assert.equal(stripVue('<style>a{}</style foo=1>keep'), 'keep')
  assert.equal(stripVue('<scr<script>x</script>ipt>y</script>keep'), 'keep')
  assert.equal(stripVue('<sty<style>x</style>le>y</style>keep'), 'keep')
  // Stripping one kind of block can expose the other.
  assert.equal(stripVue('<scr<style>x</style>ipt>y</script>keep'), 'keep')
  assert.equal(stripVue('<sty<script>x</script>le>y</style>keep'), 'keep')
})

test('stripVue only ends a block at an end tag whose name is followed by a delimiter', () => {
  assert.equal(stripVue('<script>hidden</script-not>still hidden</script>keep'), 'keep')
  assert.equal(stripVue('<style>hidden</style-not>still hidden</style>keep'), 'keep')
  assert.equal(stripVue('<script>a</script/>keep'), 'keep')
})
