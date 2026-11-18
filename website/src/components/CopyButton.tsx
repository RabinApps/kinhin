'use client'
import { useState } from 'react'

/** The copy button of a code block. It finds its block's text in the DOM, so the code itself never passes through a client component. */
export function CopyButton() {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type="button"
      className="code-copy"
      aria-label="Copy code"
      onClick={async (e) => {
        const text = e.currentTarget.closest('.code')?.querySelector('pre')?.innerText ?? ''
        try {
          await navigator.clipboard.writeText(text)
          setCopied(true)
          setTimeout(() => setCopied(false), 1500)
        } catch {
          /* clipboard blocked: nothing to do */
        }
      }}
    >
      {copied ? 'copied' : 'copy'}
    </button>
  )
}
