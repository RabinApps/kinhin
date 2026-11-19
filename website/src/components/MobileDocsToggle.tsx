'use client'
import { usePathname } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'

/**
 * Phones: the bar under the header that slides the (single, server-rendered) sidebar in from the inline start (the left
 * in a left-to-right locale). The sidebar is positioned over the page rather than inserted above it, so it is visible
 * wherever the reader has scrolled to.
 */
export function MobileDocsToggle({ title }: { title: string }) {
  const [open, setOpen] = useState(false)
  const path = usePathname()
  const bar = useRef<HTMLButtonElement>(null)
  const closeButton = useRef<HTMLButtonElement>(null)

  // The sidebar is rendered by the page, above this component's markup in no particular order: the open flag travels to
  // it as an attribute instead of a prop.
  const paint = (next: boolean) => {
    setOpen(next)
    const el = document.getElementById('docs-sidebar')
    if (next) el?.setAttribute('data-open', '')
    else el?.removeAttribute('data-open')
  }
  // A close the reader asked for puts the keyboard back on the bar; a page change closes the drawer on its own, and there
  // the new page takes the focus.
  const close = () => {
    paint(false)
    bar.current?.focus()
  }
  useEffect(() => paint(false), [path])

  // Choosing the page the reader is already on navigates nowhere, so the effect above does not fire: the link itself closes
  // the drawer. A close the reader asked for puts the keyboard back on the bar.
  useEffect(() => {
    if (!open) return
    const el = document.getElementById('docs-sidebar')
    const onClick = (e: MouseEvent) => {
      const link = e.target instanceof Element ? e.target.closest('a[href]') : null
      if (link?.getAttribute('aria-current') === 'page') close()
    }
    el?.addEventListener('click', onClick)
    return () => el?.removeEventListener('click', onClick)
  }, [open])

  // The drawer is the phone layout: leaving the breakpoint (a rotation, a resized window) hides its controls in CSS, and an
  // open flag left behind would keep the page locked with no way out. Closing it also releases the listeners below.
  useEffect(() => {
    if (!open) return
    const phone = matchMedia('(max-width: 900px)')
    const onChange = () => {
      if (!phone.matches) paint(false)
    }
    phone.addEventListener('change', onChange)
    return () => phone.removeEventListener('change', onChange)
  }, [open])

  // While the drawer is open the page behind it must not scroll, Escape must close it, and Tab must not reach the page
  // (the article and the header are still in the document under the scrim). Scrolling is stopped at the input rather than
  // with overflow, which would take the sticky header and docs bar out of their place.
  useEffect(() => {
    if (!open) return
    const el = document.getElementById('docs-sidebar')
    const outside = (target: EventTarget | null) => !(el && target instanceof Node && el.contains(target))
    // In DOM order: the close button, then the drawer's links and group summaries. Collapsed groups hold links that are not
    // focusable, so only what is rendered counts.
    const stops = () =>
      [
        closeButton.current,
        ...(el ? Array.from(el.querySelectorAll<HTMLElement>('a[href], button, summary, [tabindex]:not([tabindex="-1"])')) : []),
      ].filter((n): n is HTMLElement => !!n && (n.tagName === 'SUMMARY' || !n.closest('details:not([open])')))
    const onWheel = (e: WheelEvent) => {
      if (outside(e.target)) e.preventDefault()
    }
    const onTouchMove = (e: TouchEvent) => {
      if (outside(e.target)) e.preventDefault()
    }
    const scrollKeys = new Set(['PageDown', 'PageUp', 'Home', 'End', 'ArrowDown', 'ArrowUp', ' '])
    const onKey = (e: KeyboardEvent) => {
      // The search palette opens over the drawer (Cmd/Ctrl+K, or the header's button) and owns the keyboard while it is up:
      // a space in the query, Home/End in its input and its own Tab are not the drawer's to cancel or redirect.
      if (e.target instanceof Element && e.target.closest('[role="dialog"][aria-modal="true"]')) return
      if (e.key === 'Escape') {
        e.preventDefault()
        close()
        return
      }
      if (e.key === 'Tab') {
        const items = stops()
        if (!items.length) return
        const first = items[0]
        const last = items[items.length - 1]
        const active = document.activeElement as HTMLElement | null
        if (!active || !items.includes(active)) {
          e.preventDefault()
          ;(e.shiftKey ? last : first).focus()
        } else if (e.shiftKey && active === first) {
          e.preventDefault()
          last.focus()
        } else if (!e.shiftKey && active === last) {
          e.preventDefault()
          first.focus()
        }
        return
      }
      // The close button is outside the sidebar but part of the drawer, and Space is how a button is pressed.
      if (scrollKeys.has(e.key) && outside(e.target) && e.target !== closeButton.current) e.preventDefault()
    }
    // Opening lands on the page the reader is on, so they know where they are; the close button is the fallback.
    const current = el?.querySelector<HTMLElement>('a[aria-current="page"]')
    ;(current ?? closeButton.current)?.focus({ preventScroll: true })
    document.addEventListener('wheel', onWheel, { passive: false })
    document.addEventListener('touchmove', onTouchMove, { passive: false })
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('wheel', onWheel)
      document.removeEventListener('touchmove', onTouchMove)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  return (
    <>
      <button
        type="button"
        className="docs-bar"
        ref={bar}
        aria-expanded={open}
        aria-controls="docs-sidebar"
        onClick={() => (open ? close() : paint(true))}
      >
        <span aria-hidden="true">☰</span> {title}
      </button>
      {open && (
        <>
          <div className="docs-scrim" onClick={close} />
          <button
            type="button"
            className="docs-close"
            ref={closeButton}
            onClick={close}
            aria-label="Close documentation navigation"
          >
            ✕
          </button>
        </>
      )}
    </>
  )
}
