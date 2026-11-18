/**
 * Does this Accept header want markdown over HTML? Browsers send `text/html,…,*\/*;q=0.8`, so they never
 * match; agents send `text/markdown` (optionally with a lower-q HTML fallback).
 */
export function prefersMarkdown(accept: string | null | undefined): boolean {
  if (!accept) return false
  const q = { md: -1, html: -1, order: { md: Infinity, html: Infinity } }
  accept.split(',').forEach((part, i) => {
    const [type, ...params] = part.trim().toLowerCase().split(';')
    const weight = Number(params.map((p) => /^\s*q=([\d.]+)/.exec(p)?.[1]).find(Boolean) ?? 1)
    const key = type === 'text/markdown' || type === 'text/x-markdown' ? 'md' : type === 'text/html' || type === 'application/xhtml+xml' ? 'html' : undefined
    if (key && weight > q[key]) {
      q[key] = weight
      q.order[key] = i
    }
  })
  if (q.md <= 0) return false
  return q.md > q.html || (q.md === q.html && q.order.md < q.order.html)
}

/** Rough token estimate for the x-markdown-tokens header (about 4 characters per token). */
export const estimateTokens = (text: string): number => Math.ceil(text.length / 4)
