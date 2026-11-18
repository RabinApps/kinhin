'use client'
import { Children, isValidElement, useEffect, useState, type ReactElement, type ReactNode } from 'react'

/** "Do it yourself" / "Hand it to an AI agent" tabs. Both panels are in the HTML; the inactive one is hidden. */
export function AudienceTabs({ children }: { children: ReactNode }) {
  const panels = Children.toArray(children).filter(isValidElement) as ReactElement<{ 'data-which': string }>[]
  const [which, setWhich] = useState('human')
  useEffect(() => {
    try {
      const saved = localStorage.getItem('kinhin:audience')
      if (saved === 'human' || saved === 'agent') setWhich(saved)
    } catch {}
    if (location.hash === '#with-an-ai-agent') setWhich('agent')
  }, [])
  const pick = (w: string) => {
    setWhich(w)
    try {
      localStorage.setItem('kinhin:audience', w)
    } catch {}
  }
  return (
    <div className="tabs">
      <div className="tabs-list" role="tablist">
        {[['human', 'From the terminal'], ['agent', 'With an AI agent']].map(([w, label]) => (
          <button key={w} role="tab" aria-selected={which === w} className={which === w ? 'on' : ''} onClick={() => pick(w)} id={w === 'agent' ? 'with-an-ai-agent' : undefined}>
            {label}
          </button>
        ))}
      </div>
      {panels.map((p, i) => (
        <div key={i} hidden={p.props['data-which'] !== which} role="tabpanel">
          {p}
        </div>
      ))}
    </div>
  )
}
