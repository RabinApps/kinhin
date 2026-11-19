import assert from 'node:assert/strict'
import { test } from 'node:test'
import { toHast } from './render.ts'

/** Every element and attribute in a rendered tree, as strings to assert on. */
function walk(node: any, out: { tags: Set<string>; attrs: Set<string>; values: string[]; inputs: any[] } = { tags: new Set(), attrs: new Set(), values: [], inputs: [] }) {
  if (node?.tagName === 'input') out.inputs.push(node.properties)
  if (node?.tagName) {
    out.tags.add(node.tagName)
    for (const [k, v] of Object.entries(node.properties ?? {})) (out.attrs.add(k), out.values.push(String(v)))
  }
  for (const c of node?.children ?? []) walk(c, out)
  return out
}

const hostile = [
  '<script>alert(1)</script>',
  '<img src=x onerror="alert(1)">',
  '<a href="javascript:alert(1)">x</a>',
  '<iframe src="https://evil.example"></iframe>',
  '<object data="x"></object><embed src="x">',
  '<form action="https://evil.example"><input name=a></form>',
  '<style>body{display:none}</style>',
  '<svg onload="alert(1)"><script>1</script></svg>',
  '<div style="position:fixed;inset:0" onclick="x()">cover</div>',
  '<a href="data:text/html;base64,PHNjcmlwdD4=">x</a>',
  '[md link](javascript:alert(1))',
  '<math><mi xlink:href="javascript:alert(1)">x</mi></math>',
].join('\n\n')

test('hostile HTML in markdown is stripped', async () => {
  const { tags, attrs, values, inputs } = walk(await toHast(hostile))
  for (const t of ['script', 'iframe', 'object', 'embed', 'form', 'style']) assert.equal(tags.has(t), false, `<${t}> removed`)
  for (const a of attrs) assert.equal(/^on/i.test(a), false, `no ${a} handler`)
  assert.equal(attrs.has('style'), false, 'no inline style')
  // GitHub's schema keeps <input> for task-list checkboxes only: always a disabled checkbox, never something that submits.
  for (const i of inputs) assert.deepEqual([i.disabled, i.type], [true, 'checkbox'])
  for (const a of ['action', 'formAction', 'formaction']) assert.equal(attrs.has(a), false, `no ${a}`)
  for (const v of values) assert.equal(/^\s*(javascript|data|vbscript):/i.test(v), false, `no scripting URL: ${v.slice(0, 40)}`)
})

test('what the site needs from raw HTML survives', async () => {
  const { tags, attrs, values } = walk(await toHast('<details><summary>More</summary>\n\n<kbd>Ctrl</kbd> and <code>x</code> <sup>1</sup></details>\n\n<h2 id="mine">Mine</h2>\n\n[link](https://example.com)'))
  for (const t of ['details', 'summary', 'kbd', 'code', 'sup', 'a']) assert.ok(tags.has(t), `<${t}> kept`)
  assert.ok(values.includes('user-content-mine'), 'raw ids are prefixed, so they cannot clobber window or document properties')
  assert.ok(attrs.has('href'))
})

test('ids and names that would shadow browser globals are neutralised', async () => {
  const { values } = walk(await toHast('<a id="__next_f"></a>\n\n<img name="getElementById" src="https://example.com/x.png">'))
  assert.equal(values.includes('__next_f'), false)
  assert.equal(values.includes('getElementById'), false)
})

test('the directive elements are allowed through', async () => {
  const { tags, attrs } = walk(await toHast(':::tip[Hello]\nBody\n:::\n\n```mermaid\ngraph TD; A-->B\n```\n\n::search-next-steps\n'))
  assert.ok(tags.has('callout'))
  assert.ok(tags.has('mermaid-chart'))
  assert.ok(tags.has('search-next-steps'))
  assert.ok(attrs.has('kind') && attrs.has('chart'))
})
