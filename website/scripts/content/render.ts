import { unified } from 'unified'
import remarkParse from 'remark-parse'
import remarkGfm from 'remark-gfm'
import remarkDirective from 'remark-directive'
import remarkRehype from 'remark-rehype'
import rehypeRaw from 'rehype-raw'
import rehypeSanitize, { defaultSchema, type Options as SanitizeOptions } from 'rehype-sanitize'
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

/**
 * Markdown may contain raw HTML (docs are written for GitHub), and an old tag's docs are rendered too, so nothing from it is
 * trusted: GitHub's allowlist (no script, iframe, object, form, style, event handlers or javascript: URLs) plus the few
 * custom elements the directives above produce. Raw `id` and `name` attributes keep GitHub's `user-content-` prefix, so a page cannot
 * shadow `window` or `document` properties (DOM clobbering); heading ids added afterwards by rehype-slug are not affected.
 */
export const sanitizeSchema: SanitizeOptions = {
  ...defaultSchema,
  tagNames: [...(defaultSchema.tagNames ?? []), 'callout', 'audience-tabs', 'audience-panel', 'mermaid-chart', 'search-next-steps'],
  attributes: {
    ...defaultSchema.attributes,
    callout: ['kind', 'title'],
    'audience-panel': ['which'],
    'mermaid-chart': ['chart'],
  },
}

// Shiki writes `style="--shiki-light:#…;--shiki-dark:#…"` on every token, which repeats in the HTML and again in the RSC payload.
// Tokens get a short class instead; the few distinct colour pairs become rules in .generated/shiki.css (see shikiCss).
const tokenClasses = new Map<string, string>()
function tokenClass(style: string): string {
  let c = tokenClasses.get(style)
  if (!c) {
    c = `t${tokenClasses.size}`
    tokenClasses.set(style, c)
  }
  return c
}

/** The stylesheet for every token class handed out so far. github-dark's comment grey (#6a737d) is under 4.5:1 on the code background, so it is lifted. */
export function shikiCss(): string {
  return [...tokenClasses].map(([style, c]) => `.shiki .${c}{${style.replace(/--shiki-dark:#6a737d/i, '--shiki-dark:#9aa4b8')}}`).join('\n') + '\n'
}

const processor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkDirective)
  .use(remarkSiteDirectives)
  .use(remarkRehype, { allowDangerousHtml: true })
  .use(rehypeRaw, { passThrough: [] })
  .use(rehypeSanitize, sanitizeSchema)
  .use(rehypeMermaid)
  .use(rehypeSlug)
  .use(rehypeAnchors)
  .use(rehypeShiki, {
    themes: { light: 'github-light', dark: 'github-dark' },
    defaultColor: false,
    fallbackLanguage: 'text',
    lazy: false,
    transformers: [
      {
        name: 'kinhin-token-classes',
        span(node: any) {
          const style = node.properties?.style
          if (typeof style === 'string' && style.startsWith('--shiki-')) {
            node.properties.class = tokenClass(style)
            delete node.properties.style
          }
        },
      },
    ],
  } as never)

export async function toHast(md: string): Promise<HastRoot> {
  const tree = await processor.run(processor.parse(md))
  return tree as HastRoot
}

/** JSON without source positions (they are most of the size and the app never reads them). */
export const hastJSON = (tree: HastRoot): string => JSON.stringify(tree, (k, v) => (k === 'position' ? undefined : v))
