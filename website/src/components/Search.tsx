'use client'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import MiniSearch from 'minisearch'
import { withBase } from '../lib/base'

const options = { fields: ['title', 'headings', 'description', 'text'], storeFields: ['title', 'description'], searchOptions: { boost: { title: 4, headings: 2 }, prefix: true, fuzzy: 0.15 } }
interface Hit { id: string; title: string; description: string }

/** Cmd/Ctrl+K palette over a MiniSearch index built at deploy time (website/.generated/search-index.json). */
export function Search() {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(0)
  const [hits, setHits] = useState<Hit[]>([])
  const [ready, setReady] = useState(false)
  const index = useRef<MiniSearch | null>(null)
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') (e.preventDefault(), setOpen((o) => !o))
      else if (e.key === 'Escape') setOpen(false)
    }
    const evt = () => setOpen(true)
    addEventListener('keydown', key)
    addEventListener('kinhin:search', evt)
    return () => (removeEventListener('keydown', key), removeEventListener('kinhin:search', evt))
  }, [])

  useEffect(() => {
    if (!open) return
    input.current?.focus()
    if (!index.current) fetch(withBase('/search-index.json')).then((r) => r.text()).then((t) => { index.current = MiniSearch.loadJSON(t, options); setReady(true) }).catch(() => {})
  }, [open])

  useEffect(() => {
    const r = q.trim() && index.current ? (index.current.search(q).slice(0, 8) as unknown as Hit[]) : []
    setHits(r)
    setSel(0)
  }, [q, open, ready])

  const go = (h?: Hit) => {
    if (!h) return
    setOpen(false)
    router.push(h.id)
  }
  const copyMarkdown = async (h?: Hit) => {
    if (!h) return
    try {
      const t = await (await fetch(withBase(`${h.id}.md`))).text()
      await navigator.clipboard.writeText(t)
    } catch {}
  }

  if (!open) return null
  return (
    <div className="palette-scrim" onMouseDown={(e) => e.target === e.currentTarget && setOpen(false)}>
      <div className="palette" role="dialog" aria-modal="true" aria-label="Search">
        <div className="palette-input">
          <span aria-hidden>⌕</span>
          <input
            ref={input}
            value={q}
            placeholder="Search the docs"
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') (e.preventDefault(), setSel((s) => Math.min(hits.length - 1, s + 1)))
              else if (e.key === 'ArrowUp') (e.preventDefault(), setSel((s) => Math.max(0, s - 1)))
              else if (e.key === 'Enter') (e.metaKey || e.ctrlKey ? copyMarkdown(hits[sel]) : go(hits[sel]))
            }}
          />
          <kbd>esc</kbd>
        </div>
        <ul className="palette-list">
          {hits.map((h, i) => (
            <li key={h.id}>
              <button type="button" className={i === sel ? 'on' : ''} onMouseEnter={() => setSel(i)} onClick={() => go(h)}>
                <strong>{h.title}</strong>
                <span>{h.description}</span>
              </button>
            </li>
          ))}
          {q.trim() && hits.length === 0 && <li className="palette-empty">No results for “{q}”</li>}
        </ul>
        <div className="palette-foot">↑↓ navigate · ↵ open · ⌘↵ copy as markdown</div>
      </div>
    </div>
  )
}
