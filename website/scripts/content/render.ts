import { unified } from 'unified'
import remarkParse from 'remark-parse'
import remarkGfm from 'remark-gfm'
import remarkDirective from 'remark-directive'
import remarkRehype from 'remark-rehype'
import rehypeRaw from 'rehype-raw'
import rehypeSlug from 'rehype-slug'
import rehypeShiki from '@shikijs/rehype'
import { visit } from 'unist-util-visit'
import { toString } from 'hast-util-to-string'
import type { Root as HastRoot, Element } from 'hast'
import type { Root as MdRoot } from 'mdast'

/**
 * Markdown → hast, done at build time and stored as JSON so the Worker never ships unified or shiki:
 * the app only turns the stored tree into React (src/lib/hast.tsx).
 *
 * Directives (written by build.ts from the VitePress syntax):
 *   :::tip[Title] … :::      → <callout kind="tip" title="Title">
 *   :::::audience-tabs + ::::human / ::::agent → <audience-tabs> with <audience-panel which="…">
 *   ::search-next-steps      → <search-next-steps>
 * and ```mermaid fences → <mermaid-chart chart="…">.
 */

const CALLOUTS = new Set(['tip', 'warning', 'danger', 'info', 'details'])

function remarkSiteDirectives() {
  return (tree: MdRoot) => {
    visit(tree, (node: any) => {
      if (node.type !== 'containerDirective' && node.type !== 'leafDirective') return
      const data = (node.data ??= {})
      if (node.type === 'leafDirective' && node.name === 'search-next-steps') {
        data.hName = 'search-next-steps'
      } else if (node.type === 'containerDirective' && CALLOUTS.has(node.name)) {
        const first = node.children[0]
        let title = ''
        if (first?.data?.directiveLabel) {
          title = first.children.map((c: any) => c.value ?? '').join('')
          node.children.shift()
        }
        data.hName = 'callout'
        data.hProperties = { kind: node.name, title }
      } else if (node.type === 'containerDirective' && node.name === 'audience-tabs') {
        data.hName = 'audience-tabs'
      } else if (node.type === 'containerDirective' && (node.name === 'human' || node.name === 'agent')) {
        data.hName = 'audience-panel'
        data.hProperties = { which: node.name }
      } else {
        // An unknown container from an old tag degrades to a plain block instead of failing the snapshot.
        data.hName = 'div'
      }
    })
  }
}

function rehypeMermaid() {
  return (tree: HastRoot) => {
    visit(tree, 'element', (node: Element, index, parent) => {
      if (node.tagName !== 'pre' || !parent || index === undefined) return
      const code = node.children[0] as Element | undefined
      const cls = (code?.properties?.className as string[] | undefined) ?? []
      if (code?.tagName === 'code' && cls.includes('language-mermaid')) {
        parent.children[index] = { type: 'element', tagName: 'mermaid-chart', properties: { chart: toString(code) }, children: [] }
      }
    })
  }
}

/** A `#` link on h2/h3 so a section can be linked to. */
function rehypeAnchors() {
  return (tree: HastRoot) => {
    visit(tree, 'element', (node: Element) => {
      if ((node.tagName === 'h2' || node.tagName === 'h3') && node.properties?.id) {
        node.children.push({ type: 'element', tagName: 'a', properties: { className: ['anchor'], href: `#${node.properties.id}`, ariaLabel: 'Link to this section' }, children: [{ type: 'text', value: '#' }] })
      }
    })
  }
}

const processor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkDirective)
  .use(remarkSiteDirectives)
  .use(remarkRehype, { allowDangerousHtml: true })
  .use(rehypeRaw, { passThrough: [] })
  .use(rehypeMermaid)
  .use(rehypeSlug)
  .use(rehypeAnchors)
  .use(rehypeShiki, {
    themes: { light: 'github-light', dark: 'github-dark' },
    defaultColor: false,
    fallbackLanguage: 'text',
    lazy: false,
  } as never)

export async function toHast(md: string): Promise<HastRoot> {
  const tree = await processor.run(processor.parse(md))
  return tree as HastRoot
}

/** JSON without source positions (they are most of the size and the app never reads them). */
export const hastJSON = (tree: HastRoot): string => JSON.stringify(tree, (k, v) => (k === 'position' ? undefined : v))
