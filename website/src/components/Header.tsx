'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { useEffect, useState } from 'react'
import { nav, repoURL, siteURL } from '../../site.config.ts'
import { DOCS_VERSION } from '../lib/base'
import { stage } from '../lib/release'
import { Logo } from './Logo'

function Stars({ stars }: { stars: number | null }) {
  const label = stars === null ? 'GitHub' : stars >= 1000 ? `${(stars / 1000).toFixed(1)}k` : String(stars)
  return (
    <a className="chip-btn" href={repoURL}>
      <span aria-hidden="true">★</span>&nbsp;{label}
      <span className="sr-only-text"> stars on GitHub</span>
    </a>
  )
}

function ThemeToggle() {
  const flip = () => {
    const cur = document.documentElement.dataset.theme ?? (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')
    const next = cur === 'light' ? 'dark' : 'light'
    document.documentElement.dataset.theme = next
    try {
      localStorage.setItem('kinhin:theme', next)
    } catch {}
  }
  return (
    <button type="button" className="chip-btn" onClick={flip} aria-label="Toggle light and dark theme">
      <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden><circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" strokeWidth="1.5" /><path d="M8 1.75a6.25 6.25 0 0 1 0 12.5z" fill="currentColor" /></svg>
    </button>
  )
}

export function VersionPicker({ versions }: { versions: string[] }) {
  if (versions.length === 0) return null
  return (
    <details className="version">
      <summary className="chip-btn">{DOCS_VERSION || 'latest'}</summary>
      <div className="version-menu">
        <a href={`${siteURL}/`}>Latest (main)</a>
        {versions.map((v) => (
          <a key={v} href={`${siteURL}/${v}/`} aria-current={v === DOCS_VERSION ? 'true' : undefined}>
            {v}
          </a>
        ))}
      </div>
    </details>
  )
}

export function Header({ versions, stars }: { versions: string[]; stars: number | null }) {
  const path = usePathname()
  const [open, setOpen] = useState(false)
  // Guide and Docs share /guide/…: only the first entry for the current section is marked.
  const activeNav = nav.find((n) => path === n.link || path.startsWith('/' + n.link.split('/')[1] + '/'))
  useEffect(() => setOpen(false), [path])
  const openSearch = () => window.dispatchEvent(new Event('kinhin:search'))
  return (
    <header className="site-header">
      <div className="site-header-in">
        <Link href="/" className="brand">
          <Logo size={30} />
          <span>kinhin</span>
          {stage && <span className="badge">{stage}</span>}
        </Link>
        <nav className={`site-nav ${open ? 'open' : ''}`} aria-label="Main">
          {nav.map((n) => (
            <Link key={n.link} href={n.link} aria-current={n === activeNav ? 'page' : undefined}>
              {n.text}
            </Link>
          ))}
          <Link href="/guide/install" className="nav-download">
            Download
          </Link>
        </nav>
        <div className="site-actions">
          <Stars stars={stars} />
          <button type="button" className="chip-btn" onClick={openSearch}>
            <span aria-hidden="true">⌘ K</span>
            <span className="sr-only-text">Search</span>
          </button>
          <VersionPicker versions={versions} />
          <ThemeToggle />
          <Link href="/guide/install" className="btn btn-primary btn-sm">
            Download
          </Link>
          <button type="button" className="chip-btn menu-btn" onClick={() => setOpen((o) => !o)} aria-label="Menu" aria-expanded={open}>
            <svg width="14" height="14" viewBox="0 0 16 16" aria-hidden><path d="M2 4h12M2 8h12M2 12h12" stroke="currentColor" strokeWidth="1.5" /></svg>
          </button>
        </div>
      </div>
    </header>
  )
}
