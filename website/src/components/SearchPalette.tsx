'use client'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import MiniSearch from 'minisearch'
import { withBase } from '../lib/base'

const options = { fields: ['title', 'headings', 'description', 'text'], storeFields: ['title', 'description'], searchOptions: { boost: { title: 4, headings: 2 }, prefix: true, fuzzy: 0.15 } }
interface Hit { id: string; title: string; description: string }

/**
 * Cmd/Ctrl+K palette over a MiniSearch index built at deploy time (website/.generated/search-index.json). Loaded by
 * Search.tsx the first time it is needed, so MiniSearch and this code are not part of any page's first load.
 */
export function SearchPalette({ startOpen = false }: { startOpen?: boolean }) {
  const router = useRouter()
  const [open, setOpen] = useState(startOpen)
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(0)
  const [hits, setHits] = useState<Hit[]>([])
  const [ready, setReady] = useState(false)
  const index = useRef<MiniSearch | null>(null)
  const input = useRef<HTMLInputElement>(null)
  const opener = useRef<HTMLElement | null>(null)
  const navigated = useRef(false)

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') (e.preventDefault(), setOpen((o) => !o))
      else if (e.key === 'Escape') setOpen(false)
    }
    const evt = () => setOpen(true)
    addEventListener('keydown', key)
    addEventListener('kinhin:search', evt)
    // From here on the palette owns the shortcuts (see Search.tsx).
    ;(window as Window & { __kinhinSearch?: boolean }).__kinhinSearch = true
    return () => {
      removeEventListener('keydown', key)
      removeEventListener('kinhin:search', evt)
      ;(window as Window & { __kinhinSearch?: boolean }).__kinhinSearch = false
    }
  }, [])

  useEffect(() => {
    if (!open) return
    opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    input.current?.focus()
    // Escape or a click outside returns focus to the opener; opening a result moves on to the page instead.
    const restore = (): void => {
      if (navigated.current) navigated.current = false
      else opener.current?.focus()
    }
    if (!index.current) fetch(withBase('/search-index.json')).then((r) => r.text()).then((t) => { index.current = MiniSearch.loadJSON(t, options); setReady(true) }).catch(() => {})
    return restore
  }, [open])

  useEffect(() => {
    const r = q.trim() && index.current ? (index.current.search(q).slice(0, 8) as unknown as Hit[]) : []
    setHits(r)
    setSel(0)
  }, [q, open, ready])

  const go = (h?: Hit) => {
    if (!h) return
    navigated.current = true
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
      <div
        className="palette"
        role="dialog"
        aria-modal="true"
        aria-label="Search"
        onKeyDown={(e) => {
          // The palette is the only thing the keyboard can reach while it is open.
          if (e.key === 'Tab') (e.preventDefault(), input.current?.focus())
        }}
      >
        <div className="palette-input">
          <span aria-hidden>⌕</span>
          <input
            ref={input}
            role="combobox"
            aria-expanded={hits.length > 0}
            aria-controls="palette-list"
            aria-autocomplete="list"
            aria-activedescendant={hits.length > 0 ? `palette-opt-${sel}` : undefined}
            aria-label="Search the docs"
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
        <ul className="palette-list" id="palette-list" role="listbox" aria-label="Results">
          {hits.map((h, i) => (
            <li key={h.id} role="presentation">
              <button type="button" role="option" id={`palette-opt-${i}`} aria-selected={i === sel} tabIndex={-1} className={i === sel ? 'on' : ''} onMouseEnter={() => setSel(i)} onClick={() => go(h)}>
                <strong>{h.title}</strong>
                <span>{h.description}</span>
              </button>
            </li>
          ))}
          {q.trim() && hits.length === 0 && (
            <li className="palette-empty" role="status">
              No results for “{q}”
            </li>
          )}
        </ul>
        <div className="palette-foot">↑↓ navigate · ↵ open · ⌘↵ copy as markdown</div>
      </div>
    </div>
  )
}
