'use client'
import { useEffect, useRef, useState } from 'react'

/**
 * The tab buttons of the "terminal / AI agent" switch. The two panels are server-rendered next to it (see AudienceTabs), so
 * their content never travels through a client component: this only toggles their `hidden` attribute.
 */
export function TabList() {
  const ref = useRef<HTMLDivElement>(null)
  const [which, setWhich] = useState('human')

  useEffect(() => {
    try {
      const saved = localStorage.getItem('kinhin:audience')
      if (saved === 'human' || saved === 'agent') setWhich(saved)
    } catch {}
    if (location.hash === '#with-an-ai-agent') setWhich('agent')
  }, [])

  useEffect(() => {
    ref.current?.closest('.tabs')?.querySelectorAll<HTMLElement>('[data-which]').forEach((p) => {
      p.hidden = p.dataset.which !== which
    })
  }, [which])

  const pick = (w: string) => {
    setWhich(w)
    try {
      localStorage.setItem('kinhin:audience', w)
    } catch {}
  }

  return (
    <div
      ref={ref}
      className="tabs-list"
      role="tablist"
      aria-label="How to do this"
      onKeyDown={(e) => {
        // ARIA tabs: arrows (and Home/End) move between tabs and select them.
        const order = ['human', 'agent']
        const i = order.indexOf(which)
        const next = e.key === 'ArrowRight' || e.key === 'ArrowLeft' ? order[(i + 1) % 2] : e.key === 'Home' ? order[0] : e.key === 'End' ? order[1] : null
        if (!next) return
        e.preventDefault()
        pick(next)
        requestAnimationFrame(() => document.getElementById(next === 'agent' ? 'with-an-ai-agent' : 'tab-human')?.focus())
      }}
    >
      {[['human', 'From the terminal'], ['agent', 'With an AI agent']].map(([w, label]) => (
        <button
          key={w}
          type="button"
          role="tab"
          aria-selected={which === w}
          aria-controls={`panel-${w}`}
          tabIndex={which === w ? 0 : -1}
          className={which === w ? 'on' : ''}
          onClick={() => pick(w)}
          id={w === 'agent' ? 'with-an-ai-agent' : 'tab-human'}
        >
          {label}
        </button>
      ))}
    </div>
  )
}
