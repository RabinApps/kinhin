'use client'
import { useRef, useState, type ReactNode } from 'react'

export function CodeBlock({ children, ...rest }: { children?: ReactNode } & Record<string, unknown>) {
  const ref = useRef<HTMLPreElement>(null)
  const [copied, setCopied] = useState(false)
  async function copy() {
    try {
      await navigator.clipboard.writeText(ref.current?.innerText ?? '')
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard blocked: nothing to do */
    }
  }
  return (
    <div className="code">
      <button type="button" className="code-copy" onClick={copy} aria-label="Copy code">
        {copied ? 'copied' : 'copy'}
      </button>
      <pre ref={ref} {...rest}>
        {children}
      </pre>
    </div>
  )
}
