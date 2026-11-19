'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { sidebar, type SidebarItem } from '../../site.config.ts'

const has = (i: SidebarItem, p: string): boolean => i.link === p || (i.items ?? []).some((c) => has(c, p))

/** A release snapshot only has the pages its tag had, so links added since are left out. */
const shown = (i: SidebarItem, available?: Set<string>): boolean =>
  i.items ? i.items.some((c) => shown(c, available)) : !available || available.has(i.link!)

function Item({ item, path, available }: { item: SidebarItem; path: string; available?: Set<string> }) {
  if (item.items) {
    const children = item.items.filter((c) => shown(c, available))
    if (!children.length) return null
    return (
      <li>
        <details open={!item.collapsed || has(item, path)} className="side-sub">
          <summary>{item.text}</summary>
          <ul>
            {children.map((c) => (
              <Item key={c.text} item={c} path={path} available={available} />
            ))}
          </ul>
        </details>
      </li>
    )
  }
  return (
    <li>
      <Link href={item.link!} aria-current={item.link === path ? 'page' : undefined}>
        {item.text}
      </Link>
    </li>
  )
}

/**
 * The docs navigation, rendered once (on phones MobileDocsToggle shows it). It is a client component on purpose: it takes the
 * links from site.config in the bundle, so no markup for it travels in each page's RSC payload (a server component's output
 * would be sent again with every client-side navigation).
 */
export function Sidebar({ available }: { available?: string[] }) {
  const path = usePathname()
  const links = available ? new Set(available) : undefined
  return (
    <aside className="sidebar" id="docs-sidebar" aria-label="Documentation">
      {sidebar.filter((g) => shown(g, links)).map((g) => (
        <section key={g.text}>
          {g.collapsed ? (
            <details open={has(g, path)}>
              <summary className="side-h">{g.text}</summary>
              <ul>{g.items?.filter((i) => shown(i, links)).map((i) => <Item key={i.text} item={i} path={path} available={links} />)}</ul>
            </details>
          ) : (
            <>
              <h2 className="side-h">{g.text}</h2>
              <ul>{g.items?.filter((i) => shown(i, links)).map((i) => <Item key={i.text} item={i} path={path} available={links} />)}</ul>
            </>
          )}
        </section>
      ))}
    </aside>
  )
}
