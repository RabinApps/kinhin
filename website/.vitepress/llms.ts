import fs from 'node:fs'
import path from 'node:path'
import type { SiteConfig } from 'vitepress'
import { rewriteHref } from './docsLinks'
import { outsideFences, stripVue } from './markdownFences.ts'

/**
 * Build-time generator for the machine-readable copies of the site: a `<page>.md` next to every
 * page, `/llms.txt` (index, llmstxt.org format) and `/llms-full.txt` (every page concatenated).
 * Output goes to the build directory only; nothing here is committed.
 */

interface Page {
  /** Output path relative to the site root, e.g. `guide/why-kinhin.md`. */
  dest: string
  /** Repo-relative source path, e.g. `docs/why.md`. */
  src: string
  title: string
  description: string
  body: string
}

interface SidebarItem {
  text?: string
  link?: string
  items?: SidebarItem[]
}

interface Frontmatter {
  title?: string
  description?: string
}

const FRONTMATTER = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/

function unquote(value: string): string {
  const v = value.trim()
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) return v.slice(1, -1)
  return v
}

/** Reads the one-line `title:` and `description:` keys; anything fancier falls back to the body. */
function parseFrontmatter(raw: string): { data: Frontmatter; content: string } {
  const match = FRONTMATTER.exec(raw)
  if (!match) return { data: {}, content: raw }
  const data: Frontmatter = {}
  for (const line of match[1].split('\n')) {
    const kv = /^(title|description):\s*(.+)$/.exec(line)
    if (kv && !/^[>|][-+]?$/.test(kv[2].trim())) data[kv[1] as keyof Frontmatter] = unquote(kv[2])
  }
  return { data, content: raw.slice(match[0].length) }
}

function firstParagraph(content: string): string {
  const lines: string[] = []
  let seenH1 = false
  for (const line of content.split('\n')) {
    if (/^#\s/.test(line)) {
      seenH1 = true
      continue
    }
    if (!seenH1 && lines.length === 0 && !/^#\s/.test(content.trimStart())) seenH1 = true
    if (!seenH1) continue
    const t = line.trim()
    if (!t) {
      if (lines.length) break
      continue
    }
    if (/^(#|```|~~~|<|\||-\s|\*\s|\d+\.\s|!\[|>)/.test(t)) {
      if (lines.length) break
      continue
    }
    lines.push(t)
  }
  return lines.join(' ').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/[`*_]/g, '')
}

const rawGithub = 'https://raw.githubusercontent.com/RabinApps/kinhin/main'

export function generateLlms(siteConfig: SiteConfig, siteURL: string, base: string): void {
  const origin = `${siteURL}${base}`.replace(/\/$/, '')
  const repoRoot = siteConfig.srcDir
  // siteConfig.pages holds source paths (relative to srcDir); rewrites.map says where each is served.
  const map = siteConfig.rewrites.map as Record<string, string | undefined>
  const destToSrc = new Map<string, string>()
  const pages = new Map<string, Page>()

  for (const src of siteConfig.pages.map((p) => p.replace(/\\/g, '/'))) {
    if (!src.endsWith('.md')) continue
    const dest = map[src] ?? src
    if (dest === '404.md') continue
    destToSrc.set(dest, src)
  }
  const destSet = new Set(destToSrc.keys())

  const toMdUrl = (href: string, srcPath: string): string => {
    const rewritten = rewriteHref(href, srcPath)
    if (/^[a-z]+:/i.test(rewritten) || rewritten.startsWith('#')) return rewritten
    if (!rewritten.startsWith('/')) return rewritten
    const [pathname, anchor] = rewritten.split('#')
    const route = pathname.replace(/^\//, '')
    const candidates = [route + '.md', route.replace(/\/$/, '') + '/index.md', route === '' ? 'index.md' : '']
    const hit = candidates.find((c) => c && destSet.has(c))
    const hash = anchor ? `#${anchor}` : ''
    return hit ? `${origin}/${hit}${hash}` : `${origin}${pathname}${hash}`
  }

  // The HTML pages get hashed Vite assets, so a relative image path means nothing next to the .md copy:
  // point repo images at GitHub's raw files and public-folder images at the site.
  const toImageUrl = (href: string, srcPath: string): string => {
    if (/^([a-z]+:|#)/i.test(href)) return href
    if (href.startsWith('/')) return `${origin}${href}`
    const target = path.posix.normalize(path.posix.join(path.posix.dirname(srcPath), href))
    return fs.existsSync(path.join(repoRoot, target)) ? `${rawGithub}/${target}` : href
  }

  for (const dest of destSet) {
    const src = destToSrc.get(dest)!
    const file = path.join(repoRoot, src)
    if (!fs.existsSync(file)) continue
    const { data, content } = parseFrontmatter(fs.readFileSync(file, 'utf8'))
    let body = stripVue(content).trim()
    // Images are matched first and left alone: only page links are rewritten.
    body = outsideFences(body, (chunk) =>
      chunk.replace(
        /(!\[[^\]]*\]\([^)\s]*\))|(\]\()([^)\s]+)(\))/g,
        (_, img: string | undefined, a: string, href: string, c: string) =>
          img ? img.replace(/\(([^)\s]*)\)$/, (_m, h: string) => `(${toImageUrl(h, src)})`) : a + toMdUrl(href, src) + c,
      ),
    )
    const h1 = /^#\s+(.+)$/m.exec(body)
    const title = data.title ?? (h1 ? h1[1].trim() : dest.replace(/\.md$/, ''))
    if (!h1) body = `# ${dest === 'index.md' ? 'kinhin' : title}\n\n${dest === 'index.md' ? `> ${siteConfig.site.description}\n\n` : ''}${body}`
    pages.set(dest, {
      dest,
      src,
      title,
      description: data.description ?? firstParagraph(body),
      body,
    })
  }

  // Raw markdown next to each page.
  for (const page of pages.values()) {
    const out = path.join(siteConfig.outDir, page.dest)
    fs.mkdirSync(path.dirname(out), { recursive: true })
    fs.writeFileSync(out, page.body + '\n')
  }

  // llms.txt: sidebar order first, then the pages the sidebar does not list (blog, search-intent).
  const used = new Set<string>(['index.md'])
  const entry = (p: Page, label?: string): string => {
    const desc = p.description ? `: ${p.description}` : ''
    return `- [${label ?? p.title}](${origin}/${p.dest})${desc}`
  }
  const linkToDest = (link: string): string => {
    const route = link.replace(/^\//, '')
    if (route === '' ) return 'index.md'
    if (route.endsWith('/')) return route + 'index.md'
    return route + '.md'
  }
  // The home page is left out of the short index but opens the full text.
  const home = pages.get('index.md')
  const ordered: Page[] = home ? [home] : []
  const lines: string[] = ['# kinhin', '', `> ${siteConfig.site.description}`, '']
  const walk = (items: SidebarItem[], out: string[]): void => {
    for (const item of items) {
      if (item.link) {
        const page = pages.get(linkToDest(item.link))
        if (page && !used.has(page.dest)) {
          used.add(page.dest)
          ordered.push(page)
          out.push(entry(page, item.text))
        }
      }
      if (item.items) walk(item.items, out)
    }
  }
  const sidebar = (siteConfig.userConfig.themeConfig?.sidebar ?? []) as SidebarItem[]
  for (const group of sidebar) {
    const out: string[] = []
    walk(group.items ?? [], out)
    if (out.length) lines.push(`## ${group.text}`, '', ...out, '')
  }
  const rest = [...pages.values()].filter((p) => !used.has(p.dest))
  const blog = rest.filter((p) => p.dest.startsWith('blog/') && p.dest !== 'blog/index.md').sort((a, b) => b.dest.localeCompare(a.dest))
  const other = rest.filter((p) => !p.dest.startsWith('blog/') && p.dest.includes('/') === false)
  const leftovers = rest.filter((p) => !blog.includes(p) && !other.includes(p))
  const section = (name: string, list: Page[]): void => {
    if (!list.length) return
    lines.push(`## ${name}`, '', ...list.map((p) => entry(p)), '')
    list.forEach((p) => ordered.push(p))
  }
  section('Blog', blog)
  section('Optional', [...other, ...leftovers])
  fs.writeFileSync(path.join(siteConfig.outDir, 'llms.txt'), lines.join('\n').trimEnd() + '\n')

  // llms-full.txt: the same pages, same order, with their source URL.
  const full = [`# kinhin`, '', `> ${siteConfig.site.description}`, '']
  for (const p of ordered) {
    full.push('---', '', `Source: ${origin}/${p.dest}`, '', p.body, '')
  }
  fs.writeFileSync(path.join(siteConfig.outDir, 'llms-full.txt'), full.join('\n').trimEnd() + '\n')

  // Fail the build rather than ship an index with dead entries.
  for (const p of ordered) {
    if (!fs.existsSync(path.join(siteConfig.outDir, p.dest))) {
      throw new Error(`llms.txt lists ${p.dest} but it was not written`)
    }
  }
}
