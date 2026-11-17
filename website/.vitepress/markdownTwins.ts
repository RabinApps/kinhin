import fs from 'node:fs'
import path from 'node:path'
import type { SiteConfig } from 'vitepress'
import { rewriteHref } from './docsLinks'

/**
 * Markdown twins for AI agents. GitHub Pages cannot negotiate `Accept: text/markdown`, so the build
 * writes a clean `<page>.md` next to every published page, plus `/llms.txt` and `/llms-full.txt`.
 * Everything lands in the output directory only; nothing is committed.
 */

interface Frontmatter {
  title?: string
  description?: string
  home: boolean
  body: string
  raw: string
}

interface Twin {
  /** Published page path, e.g. `guide/quick-start.md`. */
  page: string
  /** Absolute URL of the twin. */
  url: string
  title: string
  description: string
  markdown: string
}

const unquote = (s: string) => s.trim().replace(/^(['"])(.*)\1$/, '$2')

function splitFrontmatter(source: string): Frontmatter {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(source)
  if (!m) return { home: false, body: source, raw: '' }
  const raw = m[1]
  const field = (name: string) => {
    const hit = new RegExp(`^${name}:\\s*(.+)$`, 'm').exec(raw)
    return hit ? unquote(hit[1]) : undefined
  }
  return {
    title: field('title'),
    description: field('description'),
    home: /^layout:\s*home\s*$/m.test(raw),
    body: source.slice(m[0].length),
    raw,
  }
}

/** The home page is all frontmatter (hero + features), so render those fields as markdown. */
function homeIntro(raw: string): string {
  const get = (re: RegExp) => {
    const hit = re.exec(raw)
    return hit ? unquote(hit[1]) : ''
  }
  const text = get(/^\s+text:\s*(.+)$/m)
  const tagline = get(/^\s+tagline:\s*(.+)$/m)
  const features = [...raw.matchAll(/^\s+title:\s*(.+)\n\s+details:\s*(.+)\n\s+link:\s*(\S+)/gm)]
    .map((f) => `- [${unquote(f[1])}](${unquote(f[3])}): ${unquote(f[2])}`)
    .join('\n')
  return [text && `# ${text}`, tagline, features && `## Highlights\n\n${features}`].filter(Boolean).join('\n\n')
}

/** Turn VitePress/Vue-flavoured markdown into plain markdown. Fenced code is left untouched. */
function flatten(body: string): string {
  const out: string[] = []
  let fence: string | undefined
  let skip: string | undefined
  for (const line of body.split('\n')) {
    const f = /^\s*(```+|~~~+)/.exec(line)
    if (f) {
      if (!fence) fence = f[1]
      else if (f[1].startsWith(fence[0]) && f[1].length >= fence.length) fence = undefined
      out.push(line)
      continue
    }
    if (fence) {
      out.push(line)
      continue
    }
    if (skip) {
      if (line.includes(`</${skip}>`)) skip = undefined
      continue
    }
    const block = /^\s*<(script|style)\b/.exec(line)
    if (block) {
      if (!line.includes(`</${block[1]}>`)) skip = block[1]
      continue
    }
    const container = /^:::\s*(\w+)?\s*(.*)$/.exec(line)
    if (container) {
      const kind = container[1]
      if (kind && kind !== 'details') {
        const label = container[2] || kind[0].toUpperCase() + kind.slice(1)
        out.push(`> **${label}**`, '>')
      } else if (kind === 'details') out.push(`**${container[2] || 'Details'}**`)
      continue
    }
    // Wrapper tags and bare Vue components carry no content for a reader.
    if (/^\s*<\/?div\b[^>]*>\s*$/.test(line) || /^\s*<[A-Z][\w-]*\b[^>]*\/>\s*$/.test(line)) continue
    out.push(line.replace(/^\s*<p\b[^>]*>(.*)<\/p>\s*$/, '$1'))
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim()
}

function pageUrl(page: string): string {
  return '/' + page
}

/** Make a link absolute and point site pages at their markdown twin. */
function absolutize(href: string, page: string, sourceRel: string, siteURL: string): string {
  if (/^(mailto:|tel:|#)/i.test(href)) return href
  const rewritten = rewriteHref(href, sourceRel)
  let url: URL
  try {
    url = new URL(rewritten, `${siteURL}${path.posix.dirname(pageUrl(page))}/`)
  } catch {
    return href
  }
  if (url.origin !== siteURL) return url.href
  let p = url.pathname
  if (p.endsWith('/')) p += 'index'
  if (!path.posix.extname(p)) p += '.md'
  else if (p.endsWith('.html')) p = p.replace(/\.html$/, '.md')
  return `${siteURL}${p}${url.hash}`
}

function resolveLinks(markdown: string, page: string, sourceRel: string, siteURL: string): string {
  const parts = markdown.split(/(^\s*(?:```+|~~~+)[\s\S]*?^\s*(?:```+|~~~+)\s*$)/m)
  return parts
    .map((part, i) =>
      i % 2 === 1
        ? part
        : part.replace(/(!?)\[([^\]]*)\]\(([^)\s]+)((?:\s+"[^"]*")?)\)/g, (m, bang, text, href, title) =>
            bang ? m : `[${text}](${absolutize(href, page, sourceRel, siteURL)}${title})`,
          ),
    )
    .join('')
}

function buildTwin(
  page: string,
  sourceRel: string,
  source: string,
  siteURL: string,
): Twin {
  const fm = splitFrontmatter(source)
  let body = flatten(fm.body)
  if (fm.home) body = [homeIntro(fm.raw), body].filter(Boolean).join('\n\n')
  const h1 = /^#\s+(.+)$/m.exec(body)?.[1]?.trim()
  const title = fm.title ?? h1 ?? 'Kinhin'
  if (!h1 || fm.title) body = `# ${title}\n\n${body.replace(/^#\s+.+\n+/, '')}`
  const description = fm.description ?? ''
  const withDescription = description && !fm.home ? body.replace(/^(# .+\n)/, `$1\n> ${description}\n`) : body
  const markdown = resolveLinks(withDescription, page, sourceRel, siteURL)
  return { page, url: `${siteURL}${pageUrl(page)}`, title, description, markdown: markdown + '\n' }
}

/** Where a published page's markdown lives on the web. Directory pages become `index.md`. */
export function twinPathFor(page: string): string {
  return page.replace(/\.md$/, '') + '.md'
}

export function writeMarkdownTwins(
  siteConfig: SiteConfig,
  opts: { siteURL: string; summary: string; sections: { text: string; items: { text: string; link: string }[] }[] },
): void {
  const { siteURL } = opts
  const repoRoot = siteConfig.srcDir
  const map = siteConfig.rewrites.map as Record<string, string | undefined>
  const twins = new Map<string, Twin>()

  // siteConfig.pages are source paths relative to srcDir; rewrites.map gives the published path.
  for (const sourceRel of siteConfig.pages.filter((p) => p.endsWith('.md')).sort()) {
    const page = map[sourceRel] ?? sourceRel
    const source = fs.readFileSync(path.join(repoRoot, sourceRel), 'utf8')
    const twin = buildTwin(page, sourceRel, source, siteURL)
    twins.set(page, twin)
    const dest = path.join(siteConfig.outDir, twinPathFor(page))
    fs.mkdirSync(path.dirname(dest), { recursive: true })
    fs.writeFileSync(dest, twin.markdown)
  }

  const linkFor = (link: string): Twin | undefined => {
    const clean = link.replace(/^\//, '').replace(/#.*$/, '')
    const page = clean === '' || clean.endsWith('/') ? `${clean}index.md` : `${clean}.md`
    return twins.get(page)
  }
  const listed = new Set<string>()
  const lines = [`# Kinhin`, '', `> ${opts.summary}`, '']
  const entry = (t: Twin) =>
    `- [${t.title}](${siteURL}/${twinPathFor(t.page)})${t.description ? `: ${t.description}` : ''}`
  const walk = (items: { text: string; link?: string; items?: any[] }[], out: string[]) => {
    for (const item of items) {
      const t = item.link ? linkFor(item.link) : undefined
      if (t && !listed.has(t.page)) {
        listed.add(t.page)
        out.push(entry(t))
      }
      if (item.items) walk(item.items, out)
    }
  }
  for (const section of opts.sections) {
    const out: string[] = []
    walk(section.items, out)
    if (out.length) lines.push(`## ${section.text}`, '', ...out, '')
  }
  const rest = [...twins.values()].filter((t) => !listed.has(t.page))
  if (rest.length) lines.push('## Optional', '', ...rest.map(entry), '')
  fs.writeFileSync(path.join(siteConfig.outDir, 'llms.txt'), lines.join('\n'))

  const full = [...twins.values()].map((t) => `<!-- ${t.url} -->\n\n${t.markdown}`).join('\n---\n\n')
  fs.writeFileSync(path.join(siteConfig.outDir, 'llms-full.txt'), full)
}
