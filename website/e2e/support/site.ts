import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { flattenSidebar, sidebar, type SidebarItem } from '../../site.config.ts'
import { releaseStage } from '../../src/lib/release.ts'

/**
 * What the site is supposed to contain, read from the same sources the build uses, so the tests never carry a
 * second copy of titles, routes, sidebar entries or the release number.
 */
const root = path.resolve(import.meta.dirname, '..', '..')

export interface PageMeta {
  route: string
  src: string
  title: string
  description: string
  headings: { depth: number; text: string; id: string }[]
  date?: string
}
export interface Manifest {
  version: string
  snapshot: boolean
  versions: string[]
  stars: number | null
  pages: PageMeta[]
  home: {
    hero: { text: string; tagline: string; actions: { theme: string; text: string; link: string }[] }
    features: { title: string; details: string; link: string; linkText: string }[]
    install: string[]
    questions: { group: string; links: { text: string; href: string }[] }[]
  }
}

export const manifest: Manifest = JSON.parse(readFileSync(path.join(root, '.generated/manifest.json'), 'utf8'))
export const pages = manifest.pages
export const urlOf = (route: string): string => '/' + route
export const pageOf = (route: string): PageMeta => {
  const p = pages.find((x) => x.route === route)
  if (!p) throw new Error(`no page ${route} in the manifest`)
  return p
}
/** Every route except the home page. */
export const docRoutes = pages.filter((p) => p.route !== '').map((p) => p.route)
export const sidebarLinks = flattenSidebar()
export { sidebar, flattenSidebar }
export type { SidebarItem }

/** `0.0.1-beta-7`, from the docs-sync block that follows Version.swift. */
export const releaseVersion = /releaseVersion = "([^"]+)"/.exec(readFileSync(path.join(root, 'src/data/release.ts'), 'utf8'))![1]
export const versions: string[] = JSON.parse(readFileSync(path.join(root, 'versions.json'), 'utf8'))
export const hasPublic = (file: string): boolean => existsSync(path.join(root, 'public', file))
/** True when this build produced a snapshot for the tag (CI with tags does; a bare checkout does not). */
export const hasSnapshot = (tag: string): boolean => existsSync(path.join(root, 'public', tag, 'guide', 'quick-start.html'))

/** Routes that exercise a feature, picked by what the page contains so a rename does not break the tests. */
export const mermaidRoute = pages.find((p) => /^guide\/architecture$/.test(p.route))?.route
export const markdownTitle = (p: PageMeta): string => p.title

/** BETA / ALPHA / RC for a prerelease, null once a stable version ships (the header badge and the home banner follow it). */
export const stage = releaseStage(releaseVersion)
/** The newest blog post: by date in the blog index, else the highest beta number, else the blog index. */
export const latestPostRoute: string = (() => {
  const posts = pages.filter((p) => /^blog\/.+/.test(p.route))
  const dated = posts.filter((p) => p.date).sort((a, b) => b.date!.localeCompare(a.date!) || b.route.localeCompare(a.route))
  if (dated.length) return dated[0].route
  const n = posts.map((p) => /^blog\/beta-(\d+)$/.exec(p.route)).filter(Boolean).map((m) => Number(m![1]))
  return n.length ? `blog/beta-${Math.max(...n)}` : 'blog'
})()
