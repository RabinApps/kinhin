'use client'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { sidebar, type SidebarItem } from '../../site.config.ts'

const has = (i: SidebarItem, p: string): boolean => i.link === p || (i.items ?? []).some((c) => has(c, p))

function Item({ item, path }: { item: SidebarItem; path: string }) {
  if (item.items) {
    return (
      <li>
        <details open={!item.collapsed || has(item, path)} className="side-sub">
          <summary>{item.text}</summary>
          <ul>
            {item.items.map((c) => (
              <Item key={c.text} item={c} path={path} />
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
export function Sidebar() {
  const path = usePathname()
  return (
    <aside className="sidebar" id="docs-sidebar" aria-label="Documentation">
      {sidebar.map((g) => (
        <section key={g.text}>
          {g.collapsed ? (
            <details open={has(g, path)}>
              <summary className="side-h">{g.text}</summary>
              <ul>{g.items?.map((i) => <Item key={i.text} item={i} path={path} />)}</ul>
            </details>
          ) : (
            <>
              <h2 className="side-h">{g.text}</h2>
              <ul>{g.items?.map((i) => <Item key={i.text} item={i} path={path} />)}</ul>
            </>
          )}
        </section>
      ))}
    </aside>
  )
}
