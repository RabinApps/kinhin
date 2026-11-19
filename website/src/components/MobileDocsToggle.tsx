'use client'
import { usePathname } from 'next/navigation'
import { useEffect, useState } from 'react'

/** Phones: the bar under the header that opens the (single, server-rendered) sidebar. */
export function MobileDocsToggle({ title }: { title: string }) {
  const [open, setOpen] = useState(false)
  const path = usePathname()
  const set = (next: boolean) => {
    setOpen(next)
    const el = document.getElementById('docs-sidebar')
    if (next) el?.setAttribute('data-open', '')
    else el?.removeAttribute('data-open')
  }
  // Choosing a page closes the menu: the component keeps its state across client-side navigations.
  useEffect(() => set(false), [path])
  return (
    <button type="button" className="docs-bar" aria-expanded={open} aria-controls="docs-sidebar" onClick={() => set(!open)}>
      <span aria-hidden="true">☰</span> {title}
    </button>
  )
}
