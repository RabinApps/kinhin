'use client'
import { useEffect, useRef, useState } from 'react'

/** The full-screen diagram viewer: zoom buttons, wheel, pinch and drag. Loaded only when a diagram is expanded. */
export function Viewer({ svg, onClose }: { svg: string; onClose: () => void }) {
  const [t, setT] = useState({ x: 0, y: 0, k: 1 })
  const pointers = useRef(new Map<number, { x: number; y: number }>())
  const pinch = useRef<number | null>(null)
  const closeBtn = useRef<HTMLButtonElement>(null)
  const zoom = (f: number) => setT((s) => ({ ...s, k: Math.min(6, Math.max(0.3, s.k * f)) }))
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null
    closeBtn.current?.focus()
    const keys = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
      else if (e.key === '+' || e.key === '=') zoom(1.2)
      else if (e.key === '-') zoom(1 / 1.2)
      else if (e.key === '0') setT({ x: 0, y: 0, k: 1 })
      else if (e.key === 'Tab') (e.preventDefault(), closeBtn.current?.focus())
    }
    addEventListener('keydown', keys)
    return () => (removeEventListener('keydown', keys), opener?.focus())
  }, [onClose])
  const dist = () => {
    const [a, b] = [...pointers.current.values()]
    return Math.hypot(a.x - b.x, a.y - b.y)
  }
  return (
    <div className="mermaid-view" role="dialog" aria-modal="true" aria-label="Diagram, enlarged" onWheel={(e) => zoom(e.deltaY < 0 ? 1.1 : 0.9)}>
      <div className="mermaid-bar">
        <button type="button" onClick={() => zoom(1.2)} aria-label="Zoom in">+</button>
        <button type="button" onClick={() => zoom(1 / 1.2)} aria-label="Zoom out">−</button>
        <button type="button" onClick={() => setT({ x: 0, y: 0, k: 1 })} aria-label="Reset zoom">1:1</button>
        <button type="button" ref={closeBtn} onClick={onClose}>Close</button>
      </div>
      <div
        className="mermaid-stage"
        onPointerDown={(e) => {
          pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY })
          e.currentTarget.setPointerCapture(e.pointerId)
          if (pointers.current.size === 2) pinch.current = dist()
        }}
        onPointerMove={(e) => {
          const prev = pointers.current.get(e.pointerId)
          if (!prev) return
          pointers.current.set(e.pointerId, { x: e.clientX, y: e.clientY })
          if (pointers.current.size === 2 && pinch.current) {
            const d = dist()
            zoom(d / pinch.current)
            pinch.current = d
          } else if (pointers.current.size === 1) setT((s) => ({ ...s, x: s.x + e.clientX - prev.x, y: s.y + e.clientY - prev.y }))
        }}
        onPointerUp={(e) => {
          pointers.current.delete(e.pointerId)
          pinch.current = null
        }}
        onPointerCancel={(e) => pointers.current.delete(e.pointerId)}
        onDoubleClick={() => setT({ x: 0, y: 0, k: 1 })}
        style={{ transform: `translate(${t.x}px, ${t.y}px) scale(${t.k})` }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
    </div>
  )
}
