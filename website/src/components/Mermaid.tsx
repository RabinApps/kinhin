'use client'
import { useEffect, useId, useRef, useState } from 'react'

/** Renders a mermaid diagram lazily, re-renders on theme change, and opens full screen with pan and zoom. */
export function Mermaid({ chart }: { chart: string }) {
  const id = useId().replace(/:/g, '')
  const host = useRef<HTMLDivElement>(null)
  const [svg, setSvg] = useState('')
  const [open, setOpen] = useState(false)
  const [theme, setTheme] = useState('dark')

  useEffect(() => {
    const read = () => {
      const t = document.documentElement.dataset.theme
      setTheme(t ?? (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'))
    }
    read()
    const mo = new MutationObserver(read)
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
    return () => mo.disconnect()
  }, [])

  useEffect(() => {
    let cancelled = false
    ;(async () => {
      const mermaid = (await import('mermaid')).default
      mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: theme === 'light' ? 'default' : 'dark' })
      try {
        const { svg } = await mermaid.render(`m${id}${theme}`, chart)
        if (!cancelled) setSvg(svg)
      } catch (e) {
        if (!cancelled) setSvg(`<pre>${String(e)}</pre>`)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [chart, theme, id])

  return (
    <figure className="mermaid">
      <div ref={host} dangerouslySetInnerHTML={{ __html: svg }} />
      {svg && (
        <button type="button" className="mermaid-expand" onClick={() => setOpen(true)}>
          Expand
        </button>
      )}
      {open && <Viewer svg={svg} onClose={() => setOpen(false)} />}
    </figure>
  )
}

function Viewer({ svg, onClose }: { svg: string; onClose: () => void }) {
  const [t, setT] = useState({ x: 0, y: 0, k: 1 })
  const drag = useRef<{ x: number; y: number } | null>(null)
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    addEventListener('keydown', esc)
    return () => removeEventListener('keydown', esc)
  }, [onClose])
  return (
    <div className="mermaid-view" role="dialog" aria-modal="true" onWheel={(e) => setT((s) => ({ ...s, k: Math.min(6, Math.max(0.3, s.k * (e.deltaY < 0 ? 1.1 : 0.9))) }))}>
      <button type="button" className="mermaid-close" onClick={onClose}>
        Close
      </button>
      <div
        className="mermaid-stage"
        onPointerDown={(e) => {
          drag.current = { x: e.clientX - t.x, y: e.clientY - t.y }
          e.currentTarget.setPointerCapture(e.pointerId)
        }}
        onPointerMove={(e) => drag.current && setT((s) => ({ ...s, x: e.clientX - drag.current!.x, y: e.clientY - drag.current!.y }))}
        onPointerUp={() => (drag.current = null)}
        style={{ transform: `translate(${t.x}px, ${t.y}px) scale(${t.k})` }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
    </div>
  )
}
