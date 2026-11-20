'use client'
import { useState } from 'react'
import { repoURL } from '../../site.config.ts'
import { DOCS_VERSION, withBase } from '../lib/base'

/** "Copy page as Markdown", "View .md" and "Edit on GitHub": the markdown is a static file next to the page. */
export function PageActions({ route, src }: { route: string; src: string }) {
  const [state, setState] = useState('Copy as Markdown')
  const mdPath = `/${route === '' ? 'index' : route}.md`
  async function copy() {
    try {
      const text = await (await fetch(withBase(mdPath))).text()
      await navigator.clipboard.writeText(text)
      setState('Copied')
    } catch {
      setState('Copy failed')
    }
    setTimeout(() => setState('Copy as Markdown'), 1800)
  }
  return (
    <div className="page-actions">
      <button type="button" className="chip-btn" onClick={copy}>
        {state}
      </button>
      <a className="chip-btn" href={withBase(mdPath)} type="text/markdown">
        View .md
      </a>
      <a className="chip-btn" href={`${repoURL}/blob/${DOCS_VERSION || 'main'}/${src}`}>
        Edit on GitHub
      </a>
    </div>
  )
}
