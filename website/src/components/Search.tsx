'use client'
import dynamic from 'next/dynamic'
import { useEffect, useState } from 'react'

/**
 * The search entry point that every page loads (a few hundred bytes): it listens for Cmd/Ctrl+K and the header button's
 * `kinhin:search` event, and only then fetches the palette and MiniSearch. The palette is also prefetched when the browser
 * is idle, so the first open is usually instant.
 */
const Palette = dynamic(() => import('./SearchPalette').then((m) => m.SearchPalette), { ssr: false })

export function Search() {
  const [state, setState] = useState<'idle' | 'open' | 'loaded'>('idle')

  useEffect(() => {
    if (state !== 'idle') return
    const trigger = () => setState('open')
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        trigger()
      }
    }
    addEventListener('keydown', key)
    addEventListener('kinhin:search', trigger)
    const idle = (window as { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number }).requestIdleCallback
    const prefetch = () => void import('./SearchPalette')
    const handle = idle ? idle(prefetch, { timeout: 4000 }) : window.setTimeout(prefetch, 2500)
    return () => {
      removeEventListener('keydown', key)
      removeEventListener('kinhin:search', trigger)
      if (!idle) clearTimeout(handle)
    }
  }, [state])

  // Once loaded the palette owns the shortcuts; it starts open when it was loaded because of one.
  return state === 'idle' ? null : <Palette startOpen={state === 'open'} />
}
