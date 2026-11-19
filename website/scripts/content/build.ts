/**
 * Content pipeline: reads the markdown the site publishes (docs/ + website/), rewrites links, and writes
 * everything the Next.js app and the agent-facing endpoints need into website/.generated/.
 *
 *   node scripts/content/build.ts
 *   CONTENT_ROOT=<checkout of an old tag> DOCS_VERSION=<tag> node scripts/content/build.ts   (release snapshot)
 *
 * Workers have no runtime filesystem, so all of this happens before `next build`.
 */
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import MiniSearch from 'minisearch'
import { sidebar, siteDescription, siteURL, searchNextSteps, type SidebarItem } from '../../site.config.ts'
import { outsideFences, stripVue } from './fences.ts'
import { cleanSitePath, internalLinks, mapLinks, rawGithub, resolveDocsLink, rewriteHref, splitLink, type LinkContext } from './links.ts'
import { collect } from './routes.ts'
import { hastJSON, shikiCss, toHast } from './render.ts'
import { extractHeadings, firstParagraph, parseFrontmatter, plainText, type Heading2 } from './text.ts'

const here = path.dirname(fileURLToPath(import.meta.url))
const siteDir = path.resolve(here, '..', '..')
const root = path.resolve(process.env.CONTENT_ROOT ?? path.resolve(siteDir, '..'))
const version = process.env.DOCS_VERSION || ''
const snapshot = version !== ''
const out = path.join(siteDir, '.generated')
const origin = snapshot ? `${siteURL}/${version}` : siteURL
const ref = snapshot ? version : 'main'

export interface PageMeta {
  route: string
  src: string
  title: string
  description: string
  headings: Heading2[]
  /** ISO date of a blog post, read from the blog index's list ("October 24, 2026: [Title](/blog/beta-3)"). */
  date?: string
}

const sources = collect(root)
const routes = new Map(sources.map((s) => [s.src, s.route]))
const routeSet = new Set(sources.map((s) => '/' + s.route))
const ctx: LinkContext = { root, routes, ref, origin: siteURL }

// Files served from website/public (assets, appcast, llms files) that links may point at.
const publicDir = path.join(siteDir, 'public')
const generatedPaths = new Set(['/llms.txt', '/llms-full.txt', '/appcast.xml', '/sitemap.xml', '/robots.txt', '/search-index.json'])
const assetsCopied = new Map<string, string>()

/** VitePress-flavoured markdown → what the renderer understands (container + component directives). */
function prepare(body: string): string {
  return outsideFences(stripVue(body), (chunk) =>
    chunk
      .replace(/^:::[ \t]+(tip|warning|danger|info|details)[ \t]*(.*)$/gm, (_m, kind: string, title: string) => `:::${kind}[${title.replace(/[[\]]/g, '')}]`)
      // Older tags wrote the audience tabs as a Vue component.
      .replace(/^<AudienceTabs>[ \t]*$/gm, '::::::audience-tabs')
      .replace(/^<template #(human|agent)>[ \t]*$/gm, ':::::$1')
      .replace(/^<\/template>[ \t]*$/gm, ':::::')
      .replace(/^<\/AudienceTabs>[ \t]*$/gm, '::::::')
      .replace(/^<SearchNextSteps\s*\/>[ \t]*$/gm, '::search-next-steps')
      .replace(/^<DocsGrid\s*\/>[ \t]*$/gm, ''),
  )
}

/** decodeURIComponent that does not throw on a malformed escape (`#50%`): the raw text is compared instead. */
function safeDecode(s: string): string {
  try {
    return decodeURIComponent(s)
  } catch {
    return s
  }
}

function htmlBody(src: string, body: string, errors: string[]): string {
  const dir = path.posix.dirname(src)
  return mapLinks(
    prepare(body),
    (href) => {
      // A relative link in a docs/ page that names a file the checkout does not have: report it here, instead of
      // rendering a relative URL that 404s (only the browser suite would notice, and only on pull requests).
      const resolved = resolveDocsLink(href, src, ctx)
      if (resolved.missing) errors.push(`${src}: dead link ${href} → no such file`)
      let h = resolved.href
      if (!snapshot && h.startsWith(siteURL + '/')) h = h.slice(siteURL.length)
      if (!h.startsWith('/') || h.startsWith('//')) return h
      const [p, ...rest] = h.split(/(?=[#?])/)
      const clean = cleanSitePath(p)
      const known = routeSet.has(clean) || generatedPaths.has(clean) || existsSync(path.join(publicDir, clean)) || /\.md$/.test(clean)
      if (!known) errors.push(`${src}: dead link ${href} → ${clean}`)
      const hash = rest.find((r) => r.startsWith('#'))
      if (hash && hash.length > 1 && routeSet.has(clean)) anchorLinks.push({ from: src, route: clean.slice(1), id: safeDecode(hash.slice(1)) })
      return clean + rest.join('')
    },
    (href) => {
      if (/^([a-z]+:|#)/i.test(href) || href.startsWith('/')) return href
      const target = path.posix.normalize(path.posix.join(dir, href))
      const file = path.join(root, target)
      if (!existsSync(file)) return href
      // Images that live in the repo (docs/assets/...) are copied next to the site at build time.
      const url = `/_docs/${target}`
      assetsCopied.set(file, path.join(publicDir, '_docs', target))
      return url
    },
  )
}

/** Directive syntax → plain markdown an agent reads comfortably. */
function agentBody(src: string, body: string): string {
  const dir = path.posix.dirname(src)
  const origins = origin
  const md = mapLinks(
    body,
    (href) => {
      let h = rewriteHref(href, src, ctx)
      // docs/ pages link to the site by absolute URL (https://kinhin.dev/<page>); an agent should be sent to the .md copy.
      if (h.startsWith(siteURL + '/')) h = h.slice(siteURL.length)
      if (/^[a-z][a-z0-9+.-]*:/i.test(h) || h.startsWith('#') || !h.startsWith('/')) return h
      const { pathname, suffix } = splitLink(h)
      const clean = cleanSitePath(pathname)
      if (clean === '/') return `${origins}/index.md${suffix}`
      // Only pages have a markdown copy; a link to a file (appcast.xml, launch.mp4, llms.txt) stays what it is.
      return routeSet.has(clean) ? `${origins}${clean}.md${suffix}` : `${siteURL}${clean}${suffix}`
    },
    (href) => {
      if (/^([a-z]+:|#)/i.test(href)) return href
      if (href.startsWith('/')) return `${origins}${href}`
      const target = path.posix.normalize(path.posix.join(dir, href))
      return existsSync(path.join(root, target)) ? `${rawGithub}/${ref}/${target}` : href
    },
  )
  const label = (k: string) => ({ tip: 'Tip', warning: 'Warning', danger: 'Danger', info: 'Note', details: 'Details' })[k] ?? k
  return outsideFences(prepare(md), (chunk) =>
    chunk
      .replace(/^:{3,}(tip|warning|danger|info|details)\[(.*)\]$/gm, (_m, k: string, t: string) => `**${label(k)}${t ? `: ${t}` : ''}**\n`)
      .replace(/^:{3,}audience-tabs\s*\n/gm, '')
      .replace(/^:{3,}human\s*$/gm, '**If you are doing this yourself**\n')
      .replace(/^:{3,}agent\s*$/gm, '**If you are an AI agent**\n')
      .replace(/^:{3,}\s*$\n?/gm, '')
      .replace(/^::search-next-steps\s*$/gm, `## Next steps\n\n${searchNextSteps.map((l) => `- [${l.text}](${origins}${l.href}.md): ${l.note}`).join('\n')}`)
      .replace(/\n{3,}/g, '\n\n'),
  )
}

mkdirSync(out, { recursive: true })
rmSync(path.join(out, 'pages'), { recursive: true, force: true })
rmSync(path.join(out, 'md'), { recursive: true, force: true })
mkdirSync(path.join(out, 'pages'), { recursive: true })
mkdirSync(path.join(out, 'md'), { recursive: true })
rmSync(path.join(publicDir, '_docs'), { recursive: true, force: true })

const errors: string[] = []
/** `[text](/page#anchor)` links, checked against the rendered headings once every page is built. */
const anchorLinks: { from: string; route: string; id: string }[] = []
const idsByRoute = new Map<string, Set<string>>()
const pages: PageMeta[] = []
const agentPages = new Map<string, { meta: PageMeta; md: string }>()
const searchDocs: { id: string; title: string; description: string; headings: string; text: string }[] = []
const fileName = (route: string) => (route === '' ? 'index' : route.replace(/\//g, '__'))

let home: Record<string, unknown> | undefined
for (const { src, route } of sources) {
  const raw = readFileSync(path.join(root, src), 'utf8')
  const { data, content } = parseFrontmatter(raw)
  if (route === '') {
    home = { ...data, ...parseHome(content) }
    // The home page is composed in React; its markdown copy is built from the same data below.
  }
  let body = htmlBody(src, content, errors)
  const { h1, headings } = extractHeadings(body)
  const title = (data.title as string | undefined) ?? h1 ?? (route === '' ? 'kinhin' : route)
  const description = (data.description as string | undefined) ?? firstParagraph(body)
  // The page header shows the title, so a leading H1 is dropped from the body.
  if (h1) body = body.replace(/^#[ \t]+.+\n+/m, '')
  const meta: PageMeta = { route, src, title, description, headings }
  pages.push(meta)
  const tree = await toHast(body.trim() + '\n')
  idsByRoute.set(route, collectIds(tree))
  writeFileSync(path.join(out, 'pages', fileName(route) + '.json'), hastJSON(tree))
  let md = agentBody(src, content).trim()
  if (!/^#\s/m.test(md)) md = `# ${route === '' ? 'kinhin' : title}\n\n${route === '' ? `> ${siteDescription}\n\n` : ''}${md}`
  agentPages.set(route, { meta, md })
  const text = plainText(body)
  if (route !== '') searchDocs.push({ id: '/' + route, title, description, headings: headings.map((h) => h.text).join(' · '), text: text.slice(0, 8000) })
}

/** Every `id` in a rendered page: headings of any level and hand-written ids both count as anchor targets. */
function collectIds(node: any, ids = new Set<string>()): Set<string> {
  if (node?.properties?.id) ids.add(String(node.properties.id))
  for (const c of node?.children ?? []) collectIds(c, ids)
  return ids
}

function parseHome(content: string): Record<string, unknown> {
  const section = (name: string): string => {
    const m = new RegExp(`^## ${name}[^\\n]*\\n([\\s\\S]*?)(?=^## |$(?![\\s\\S]))`, 'm').exec(content)
    return m ? m[1] : ''
  }
  const install = /```bash\n([\s\S]*?)```/.exec(section('Up and running'))?.[1].trim().split('\n') ?? []
  const questions: { group: string; links: { text: string; href: string }[] }[] = []
  for (const line of section('Common questions').split('\n')) {
    const g = /^\*\*(.+)\*\*$/.exec(line.trim())
    const l = /^- \[(.+)\]\((.+)\)$/.exec(line.trim())
    if (g) questions.push({ group: g[1], links: [] })
    else if (l && questions.length) questions[questions.length - 1].links.push({ text: l[1], href: cleanSitePath(l[2]) })
  }
  return { install, questions }
}

if (!home) errors.push('website/index.md not found')

// A link to `/page#anchor` must land on a heading that exists (GitHub and the site slug headings the same way).
for (const a of anchorLinks) {
  const ids = idsByRoute.get(a.route)
  if (ids && !ids.has(a.id)) errors.push(`${a.from}: dead anchor /${a.route}#${a.id}`)
}

// Blog post dates live in the hand-written blog index; the manifest carries them for structured data.
const blogIndex = sources.find((x) => x.route === 'blog')
if (blogIndex) {
  const text = readFileSync(path.join(root, blogIndex.src), 'utf8')
  for (const [, when, route] of text.matchAll(/^- \*\*([A-Z][a-z]+ \d{1,2}, \d{4}):\s*\[[^\]]*\]\(\/(blog\/[^)#]+)\)/gm)) {
    const d = new Date(`${when} 12:00:00 UTC`)
    const page = pages.find((x) => x.route === route)
    if (page && !Number.isNaN(d.getTime())) page.date = d.toISOString().slice(0, 10)
  }
}

const flat: { text: string; link: string }[] = []
const walk = (items: SidebarItem[]): void => {
  for (const i of items) {
    if (i.link) flat.push({ text: i.text, link: i.link })
    if (i.items) walk(i.items)
  }
}
walk(sidebar)
for (const l of flat) if (!routeSet.has(l.link) && !snapshot) errors.push(`sidebar: ${l.link} has no page`)

// --- agent-facing output: <route>.md, llms.txt, llms-full.txt -----------------------------------
const mdName = (route: string) => (route === '' ? 'index' : route)
function homeMarkdown(): string {
  const h = home as Record<string, any>
  const lines = ['# kinhin', '', `> ${h.hero?.tagline ?? siteDescription}`, '', `**${h.hero?.text ?? ''}**`, '']
  for (const f of h.features ?? []) lines.push(`- **${f.title}**: ${f.details} [${f.linkText}](${origin}${f.link}.md)`)
  lines.push('', '## Up and running in three commands', '', '```bash', ...(h.install ?? []), '```', '', '## Common questions', '')
  for (const q of h.questions ?? []) lines.push(`**${q.group}**`, '', ...q.links.map((l: any) => `- [${l.text}](${origin}${l.href}.md)`), '')
  return lines.join('\n')
}
if (agentPages.has('')) agentPages.get('')!.md = homeMarkdown()

const abs = (route: string) => `${origin}/${mdName(route)}.md`
const used = new Set<string>([''])
const lines = ['# kinhin', '', `> ${siteDescription}`, '']
const ordered = [agentPages.get('')].filter(Boolean) as { meta: PageMeta; md: string }[]
const entry = (p: PageMeta, label?: string) => `- [${label ?? p.title}](${abs(p.route)})${p.description ? `: ${p.description}` : ''}`
for (const group of sidebar) {
  const sec: string[] = []
  const w = (items: SidebarItem[]): void => {
    for (const i of items) {
      const route = i.link?.replace(/^\//, '')
      if (route !== undefined && agentPages.has(route) && !used.has(route)) {
        used.add(route)
        ordered.push(agentPages.get(route)!)
        sec.push(entry(agentPages.get(route)!.meta, i.text))
      }
      if (i.items) w(i.items)
    }
  }
  w(group.items ?? [])
  if (sec.length) lines.push(`## ${group.text}`, '', ...sec, '')
}
const rest = [...agentPages.values()].filter((p) => !used.has(p.meta.route))
const blog = rest.filter((p) => p.meta.route.startsWith('blog/')).sort((a, b) => b.meta.route.localeCompare(a.meta.route))
const other = rest.filter((p) => !blog.includes(p))
for (const [name, list] of [['Blog', blog], ['Optional', other]] as const) {
  if (!list.length) continue
  lines.push(`## ${name}`, '', ...list.map((p) => entry(p.meta)), '')
  ordered.push(...list)
}
for (const [route, { md }] of agentPages) {
  const file = path.join(out, 'md', mdName(route) + '.md')
  mkdirSync(path.dirname(file), { recursive: true })
  writeFileSync(file, md + '\n')
}
writeFileSync(path.join(out, 'llms.txt'), lines.join('\n').trimEnd() + '\n')
const full = ['# kinhin', '', `> ${siteDescription}`, '']
for (const p of ordered) full.push('---', '', `Source: ${abs(p.meta.route)}`, '', p.md, '')
writeFileSync(path.join(out, 'llms-full.txt'), full.join('\n').trimEnd() + '\n')

writeFileSync(path.join(out, 'shiki.css'), shikiCss())

// --- search index --------------------------------------------------------------------------------
const mini = new MiniSearch({ fields: ['title', 'headings', 'description', 'text'], storeFields: ['title', 'description'], searchOptions: { boost: { title: 4, headings: 2 }, prefix: true, fuzzy: 0.15 } })
mini.addAll(searchDocs)
writeFileSync(path.join(out, 'search-index.json'), JSON.stringify(mini))

// --- manifest ------------------------------------------------------------------------------------
const versions = JSON.parse(readFileSync(path.join(siteDir, 'versions.json'), 'utf8')) as string[]

// The GitHub star count is read once per build, so visitors' browsers never call GitHub. A failed lookup (offline, rate limited)
// shows a plain "GitHub" chip. Set GITHUB_TOKEN in CI to avoid the anonymous rate limit.
async function stargazers(): Promise<number | null> {
  if (snapshot) return null
  try {
    const res = await fetch('https://api.github.com/repos/RabinApps/kinhin', {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'kinhin-site-build', ...(process.env.GITHUB_TOKEN ? { authorization: `Bearer ${process.env.GITHUB_TOKEN}` } : {}) },
      signal: AbortSignal.timeout(8000),
    })
    const n = res.ok ? ((await res.json()) as { stargazers_count?: number }).stargazers_count : undefined
    return typeof n === 'number' ? n : null
  } catch {
    return null
  }
}
const stars = await stargazers()
writeFileSync(path.join(out, 'manifest.json'), JSON.stringify({ version, snapshot, versions, stars, pages, home }, null, 1))

for (const [from, to] of assetsCopied) {
  mkdirSync(path.dirname(to), { recursive: true })
  cpSync(from, to)
}

// Content budgets, enforced like a dead link (warnings in a snapshot build): the search index and every result card
// show the description, so it must be a real sentence and not be shared with another page. Blog post titles name
// three release features at once and are long on purpose, so the <title> budget covers the guide pages only.
{
  const seen = new Map<string, string>()
  for (const p of pages) {
    if (p.route === '') continue
    if (p.description.length < 40) errors.push(`${p.src}: description is short (${p.description.length} chars); search results show it`)
    if (!p.route.startsWith('blog/') && p.title.length > 70) errors.push(`${p.src}: title is ${p.title.length} chars; <title> is cut near 60`)
    const dup = seen.get(p.description)
    if (dup) errors.push(`${p.src} and ${dup} share a description`)
    seen.set(p.description, p.src)
  }
}

if (errors.length) {
  const msg = `content: ${errors.length} problem(s):\n  ${errors.join('\n  ')}`
  if (snapshot) console.warn(msg)
  else {
    console.error(msg)
    process.exit(1)
  }
}
console.log(`content: ${pages.length} pages${snapshot ? ` (snapshot ${version})` : ''}, ${assetsCopied.size} images`)
