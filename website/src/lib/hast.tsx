import type { ReactNode } from 'react'
import { Fragment, jsx, jsxs } from 'react/jsx-runtime'
import Link from 'next/link'
import { toJsxRuntime } from 'hast-util-to-jsx-runtime'
import type { Root } from 'hast'
import { searchNextSteps } from '../../site.config.ts'
import { AudienceTabs } from '../components/AudienceTabs'
import { CodeBlock } from '../components/CodeBlock'
import { Mermaid } from '../components/Mermaid'
import { withBase } from './base'

/** The stored hast tree (built by scripts/content/render.ts) → React, with the site's components. */
const components = {
  a: ({ href = '', children, ...rest }: any) =>
    href.startsWith('/') && !href.startsWith('//') ? (
      <Link href={href} {...rest}>
        {children}
      </Link>
    ) : /^https?:/.test(href) ? (
      <a href={href} rel="noopener" {...rest}>
        {children}
      </a>
    ) : (
      <a href={href} {...rest}>
        {children}
      </a>
    ),
  img: ({ src = '', alt = '', ...rest }: any) => <img src={withBase(src)} alt={alt} loading="lazy" {...rest} />,
  table: ({ children, ...rest }: any) => (
    <div className="table-wrap">
      <table {...rest}>{children}</table>
    </div>
  ),
  pre: ({ children, ...rest }: any) => <CodeBlock {...rest}>{children}</CodeBlock>,
  callout: ({ kind, title, children }: any) => (
    <aside className={`callout callout-${kind}`}>
      <div className="callout-title">{title || { tip: 'Tip', warning: 'Warning', danger: 'Danger', info: 'Note', details: 'Details' }[kind as string]}</div>
      {children}
    </aside>
  ),
  'audience-tabs': ({ children }: any) => <AudienceTabs>{children}</AudienceTabs>,
  // Server components are resolved before they reach the client tabs, so the panel carries its audience as a data attribute.
  'audience-panel': ({ which, children }: any) => <div data-which={which}>{children}</div>,
  'mermaid-chart': ({ chart }: any) => <Mermaid chart={chart} />,
  'search-next-steps': () => (
    <section className="next-steps">
      <h2>Next steps</h2>
      <ul>
        {searchNextSteps.map((l) => (
          <li key={l.href}>
            <Link href={l.href}>{l.text}</Link>: {l.note}
          </li>
        ))}
      </ul>
    </section>
  ),
}

export function renderHast(tree: Root): ReactNode {
  return toJsxRuntime(tree, { Fragment, jsx, jsxs, components: components as never, elementAttributeNameCase: 'react' } as never)
}
