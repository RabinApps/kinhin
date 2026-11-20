import type { ReactNode } from 'react'
import { CopyButton } from './CopyButton'

/** A highlighted code block: server-rendered, with only the copy button on the client. */
export function CodeBlock({ children, ...rest }: { children?: ReactNode } & Record<string, unknown>) {
  return (
    <div className="code">
      <CopyButton />
      <pre {...rest}>{children}</pre>
    </div>
  )
}
