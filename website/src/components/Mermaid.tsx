'use client'
import dynamic from 'next/dynamic'
import { useEffect, useId, useRef, useState } from 'react'

// The viewer is a separate chunk, fetched on first hover or click of "Expand".
const loadViewer = () => import('./MermaidViewer').then((m) => m.Viewer)
const Viewer = dynamic(loadViewer, { ssr: false })

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
        <button type="button" className="mermaid-expand" onClick={() => setOpen(true)} onPointerEnter={() => void loadViewer()} onFocus={() => void loadViewer()}>
          Expand
        </button>
      )}
      {open && <Viewer svg={svg} onClose={() => setOpen(false)} />}
    </figure>
  )
}
