'use client'
import dynamic from 'next/dynamic'
import { useEffect, useState } from 'react'

/**
 * The search entry point that every page loads (a few hundred bytes): it listens for Cmd/Ctrl+K and the header button's
 * `kinhin:search` event, and only then fetches the palette and MiniSearch. The palette is also prefetched when the browser
 * is idle, so the first open is usually instant.
 *
 * The launcher keeps listening for the whole life of the page: until the palette has mounted (it sets window.__kinhinSearch) a
 * shortcut loads it and opens it, and every press is preventDefault-ed so the browser's own Ctrl+K never fires mid-load. Once the
 * palette is there it owns the toggling.
 */
const Palette = dynamic(() => import('./SearchPalette').then((m) => m.SearchPalette), { ssr: false })

type SearchWindow = Window & { __kinhinSearch?: boolean }

export function Search() {
  const [load, setLoad] = useState(false)

  useEffect(() => {
    const trigger = () => {
      if (!(window as SearchWindow).__kinhinSearch) setLoad(true)
    }
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
  }, [])

  // Loaded because of a shortcut or the header button, so it starts open.
  return load ? <Palette startOpen /> : null
}
