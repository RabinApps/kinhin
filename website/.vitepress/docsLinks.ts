import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type { MarkdownRenderer } from 'vitepress'

/**
 * The site reads `docs/` in place (see `srcDir` and `rewrites` in config.ts), so the pages there
 * are written for GitHub: links are relative to the file and point at the README and at source.
 * This plugin rewrites them while rendering, so `docs/` stays the only copy.
 */

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const githubBlob = 'https://github.com/RabinApps/kinhin/blob/main'

/** Repo-relative markdown path → site path, for every `docs/` page the site publishes. */
export const docRewrites: Record<string, string> = {
  'docs/why.md': 'guide/why-kinhin.md',
  'docs/forges/README.md': 'guide/forges/index.md',
}

/** `docs/` pages the site does not publish (kept in sync with `srcExclude` in config.ts): they link to GitHub. */
const unpublished = new Set(['docs/app.md', 'docs/architecture.md', 'docs/adding-a-forge.md'])

/** `docs/<name>.md` and `docs/forges/<name>.md` keep their names under `/guide/`. */
export function sitePath(repoPath: string): string | undefined {
  if (unpublished.has(repoPath)) return undefined
  if (docRewrites[repoPath]) return docRewrites[repoPath]
  if (/^docs\/forges\/[^/]+\.md$/.test(repoPath)) return repoPath.replace(/^docs\//, 'guide/')
  if (/^docs\/[^/]+\.md$/.test(repoPath)) return repoPath.replace(/^docs\//, 'guide/')
  return undefined
}

function toUrl(sitePage: string): string {
  const url = '/' + sitePage.replace(/\.md$/, '')
  return url.endsWith('/index') ? url.slice(0, -'index'.length) : url
}

export function rewriteHref(href: string, relativePath: string): string {
  if (!relativePath.startsWith('docs/') || /^([a-z]+:|#|\/)/i.test(href)) return href
  const [file, anchor] = href.split('#')
  const target = path.posix.normalize(path.posix.join(path.posix.dirname(relativePath), file))
  const hash = anchor ? `#${anchor}` : ''
  if (target === 'README.md') return '/'
  const published = sitePath(target)
  if (published && existsSync(path.join(repoRoot, target))) return toUrl(published) + hash
  if (existsSync(path.join(repoRoot, target))) return `${githubBlob}/${target}${hash}`
  return href
}

export function docsLinks(md: MarkdownRenderer): void {
  md.core.ruler.push('kinhin_docs_links', (state) => {
    // env.relativePath is the rewritten site path; the real file tells where the links resolve from.
    const source: string = state.env?.realPath ?? state.env?.path ?? ''
    const relativePath = path.relative(repoRoot, source).split(path.sep).join('/')
    for (const block of state.tokens) {
      for (const token of block.children ?? []) {
        if (token.type !== 'link_open') continue
        const href = token.attrGet('href')
        if (!href) continue
        const rewritten = rewriteHref(href, relativePath)
        if (rewritten !== href) token.attrSet('href', rewritten)
        // "← Back to README" is GitHub navigation; on the site it goes home.
        const idx = block.children!.indexOf(token)
        const text = block.children![idx + 1]
        if (text?.type === 'text' && text.content === '← Back to README') text.content = '← Home'
      }
    }
  })
}
