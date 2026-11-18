'use client'
import { useState } from 'react'

/** Phones: the bar under the header that opens the (single, server-rendered) sidebar. */
export function MobileDocsToggle({ title }: { title: string }) {
  const [open, setOpen] = useState(false)
  return (
    <button
      type="button"
      className="docs-bar"
      aria-expanded={open}
      aria-controls="docs-sidebar"
      onClick={() => {
        const next = !open
        setOpen(next)
        const el = document.getElementById('docs-sidebar')
        if (next) el?.setAttribute('data-open', '')
        else el?.removeAttribute('data-open')
      }}
    >
      <span aria-hidden="true">☰</span> {title}
    </button>
  )
}
