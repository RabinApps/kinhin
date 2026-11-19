'use client'
import dynamic from 'next/dynamic'
import { useEffect, useRef, useState } from 'react'

/**
 * A diagram in a docs page. Mermaid is a heavy library (about 1.6 MB gzipped with its diagram types), so it is:
 *  - never part of the server bundle (`ssr: false`: the Worker only ships HTML),
 *  - fetched only when the diagram comes within 300px of the viewport, so a page whose diagrams are below the fold, or a
 *    reader who never scrolls to them, does not download it.
 * Until then (and without JavaScript, and for crawlers and agents) the diagram's source is shown as text.
 */
const Mermaid = dynamic(() => import('./Mermaid').then((m) => m.Mermaid), {
  ssr: false,
  loading: () => <figure className="mermaid" aria-busy="true" />,
})

export function MermaidLazy({ chart }: { chart: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const [near, setNear] = useState(false)
  useEffect(() => {
    const el = ref.current
    if (!el || near) return
    if (!('IntersectionObserver' in window)) return setNear(true)
    const io = new IntersectionObserver((entries) => entries.some((e) => e.isIntersecting) && (setNear(true), io.disconnect()), { rootMargin: '300px' })
    io.observe(el)
    return () => io.disconnect()
  }, [near])
  return <div ref={ref}>{near ? <Mermaid chart={chart} /> : (
    <figure className="mermaid mermaid-source" aria-label="Diagram source (loading)">
      <pre>{chart}</pre>
    </figure>
  )}</div>
}
