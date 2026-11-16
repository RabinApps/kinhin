import assert from 'node:assert/strict'
import { test } from 'node:test'
import { outsideFences, stripVue } from './markdownFences.ts'

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

test('stripVue removes script/style blocks outside fences only', () => {
  const md = ['<script setup>\nconst a = 1\n</script>', '', '# T', '', '```html', '<script>x</script>', '```', '<style>a{}</style>', 'end'].join('\n')
  const out = stripVue(md)
  assert.ok(!out.includes('const a'))
  assert.ok(!out.includes('a{}'))
  assert.ok(out.includes('<script>x</script>'))
  assert.ok(out.includes('end'))
})
