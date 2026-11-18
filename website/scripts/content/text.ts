import { parse as parseYaml } from 'yaml'
import GithubSlugger from 'github-slugger'
import { unified } from 'unified'
import remarkParse from 'remark-parse'
import remarkGfm from 'remark-gfm'
import { visit } from 'unist-util-visit'
import type { Heading, Root } from 'mdast'

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/

export interface Frontmatter {
  title?: string
  description?: string
  [key: string]: unknown
}

export function parseFrontmatter(raw: string): { data: Frontmatter; content: string } {
  const m = FRONTMATTER.exec(raw)
  if (!m) return { data: {}, content: raw }
  let data: Frontmatter = {}
  try {
    data = (parseYaml(m[1]) as Frontmatter) ?? {}
  } catch {
    /* a malformed block is treated as no frontmatter, like the old reader */
  }
  return { data, content: raw.slice(m[0].length) }
}

export function firstParagraph(content: string): string {
  const lines: string[] = []
  let seenH1 = !/^#\s/m.test(content)
  for (const line of content.split('\n')) {
    if (/^#\s/.test(line)) {
      seenH1 = true
      continue
    }
    if (!seenH1) continue
    const t = line.trim()
    if (!t) {
      if (lines.length) break
      continue
    }
    if (/^(#|```|~~~|<|\||-\s|\*\s|\d+\.\s|!\[|>|:::)/.test(t)) {
      if (lines.length) break
      continue
    }
    lines.push(t)
  }
  return lines.join(' ').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[`*_]/g, '')
}

const processor = unified().use(remarkParse).use(remarkGfm)

function nodeText(node: unknown): string {
  const n = node as { value?: string; children?: unknown[] }
  if (typeof n.value === 'string') return n.value
  return (n.children ?? []).map(nodeText).join('')
}

export interface Heading2 {
  depth: number
  text: string
  id: string
}

/** h2/h3 with the same ids rehype-slug gives them at render time (both use github-slugger). */
export function extractHeadings(md: string): { h1?: string; headings: Heading2[] } {
  const tree = processor.parse(md) as Root
  const slugger = new GithubSlugger()
  const headings: Heading2[] = []
  let h1: string | undefined
  visit(tree, 'heading', (node: Heading) => {
    const text = nodeText(node).trim()
    const id = slugger.slug(text)
    if (node.depth === 1 && h1 === undefined) h1 = text
    else if (node.depth === 2 || node.depth === 3) headings.push({ depth: node.depth, text, id })
  })
  return { h1, headings }
}

/** Plain text of a markdown page, for the search index. */
export function plainText(md: string): string {
  const tree = processor.parse(md) as Root
  const out: string[] = []
  visit(tree, (node) => {
    if (node.type === 'text' || node.type === 'inlineCode') out.push((node as { value: string }).value)
    else if (node.type === 'code') out.push((node as { value: string }).value)
    else if (node.type === 'paragraph' || node.type === 'heading' || node.type === 'listItem') out.push('\n')
  })
  return out.join(' ').replace(/\s+/g, ' ').trim()
}
