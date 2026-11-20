'use client'
import { useEffect, useState } from 'react'

export function Toc({ headings }: { headings: { depth: number; text: string; id: string }[] }) {
  const [active, setActive] = useState(headings[0]?.id)
  useEffect(() => {
    const els = headings.map((h) => document.getElementById(h.id)).filter(Boolean) as HTMLElement[]
    const io = new IntersectionObserver((entries) => entries.forEach((e) => e.isIntersecting && setActive(e.target.id)), { rootMargin: '-80px 0px -70% 0px' })
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [headings])
  if (headings.length < 2) return null
  return (
    <nav className="toc" aria-label="On this page">
      <h2>On this page</h2>
      <ul>
        {headings.map((h) => (
          <li key={h.id} className={`d${h.depth}`}>
            <a href={`#${h.id}`} aria-current={active === h.id ? 'true' : undefined}>
              {h.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}
