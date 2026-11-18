import fs from 'node:fs'
import path from 'node:path'
import type { Root } from 'hast'
import { sidebar, flattenSidebar, type SidebarItem } from '../../site.config.ts'

/** Server-only reads of website/.generated (written by scripts/content/build.ts before `next build`). */
const dir = path.join(process.cwd(), '.generated')

export interface PageMeta {
  route: string
  src: string
  title: string
  description: string
  headings: { depth: number; text: string; id: string }[]
  date?: string
}
export interface HomeData {
  hero: { name?: string; text: string; tagline: string; actions: { theme: string; text: string; link: string }[] }
  features: { icon?: { src: string }; title: string; details: string; link: string; linkText: string }[]
  install: string[]
  questions: { group: string; links: { text: string; href: string }[] }[]
}
export interface Manifest {
  version: string
  snapshot: boolean
  versions: string[]
  /** GitHub stars when the build could read them, otherwise null. */
  stars: number | null
  pages: PageMeta[]
  home: HomeData
}

let cached: Manifest | undefined
export function getManifest(): Manifest {
  return (cached ??= JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')) as Manifest)
}

const fileName = (route: string) => (route === '' ? 'index' : route.replace(/\//g, '__'))

export function getPage(route: string): { meta: PageMeta; tree: Root } | undefined {
  const meta = getManifest().pages.find((p) => p.route === route)
  if (!meta) return undefined
  const tree = JSON.parse(fs.readFileSync(path.join(dir, 'pages', fileName(route) + '.json'), 'utf8')) as Root
  return { meta, tree }
}

export function getMarkdown(route: string): string | undefined {
  const file = path.join(dir, 'md', (route === '' ? 'index' : route) + '.md')
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : undefined
}

export const readGenerated = (name: string): string => fs.readFileSync(path.join(dir, name), 'utf8')

/** Title of the sidebar group holding `link`, and the neighbours in reading order. */
export function sidebarContext(route: string): { group?: string; prev?: { text: string; link: string }; next?: { text: string; link: string } } {
  const link = '/' + route
  const flat = flattenSidebar()
  const i = flat.findIndex((l) => l.link === link)
  const group = sidebar.find((g) => contains(g, link))?.text
  return { group, prev: i > 0 ? flat[i - 1] : undefined, next: i >= 0 && i < flat.length - 1 ? flat[i + 1] : undefined }
}
const contains = (item: SidebarItem, link: string): boolean => item.link === link || (item.items ?? []).some((c) => contains(c, link))

/** The newest release post, `/blog/beta-N` with the largest N; `/blog` when there is none. Keeps the home banner current without an edit. */
export function latestPost(): string {
  const n = getManifest()
    .pages.map((p) => /^blog\/beta-(\d+)$/.exec(p.route))
    .filter((m): m is RegExpExecArray => m !== null)
    .map((m) => Number(m[1]))
  return n.length ? `/blog/beta-${Math.max(...n)}` : '/blog'
}
