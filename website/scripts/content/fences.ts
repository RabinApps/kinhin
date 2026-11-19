/** Fence-aware helpers for the markdown copies (kept import-free so node:test can load them). */

/**
 * Applies `fn` to each run of lines outside fenced code blocks, leaving the fences untouched.
 * A fence closes on the same character with at least the opening length and nothing after it
 * (CommonMark), so a four-backtick block can hold a three-backtick example. Any mix of blockquote markers, list
 * markers and indentation before a fence is ignored, so fences inside `>` quotes and list items
 * (including one opened on the item's own line) count too.
 */
export function outsideFences(text: string, fn: (chunk: string) => string): string {
  const out: string[] = []
  let chunk: string[] = []
  let open: { char: string; len: number } | undefined
  const flush = (): void => {
    if (chunk.length) out.push(fn(chunk.join('\n')))
    chunk = []
  }
  for (const line of text.split('\n')) {
    const m = /^(?:[ \t>]|(?:[-*+]|\d+[.)])[ \t])*(`{3,}|~{3,})(.*)$/.exec(line)
    if (open) {
      out.push(line)
      if (m && m[1][0] === open.char && m[1].length >= open.len && m[2].trim() === '') open = undefined
    } else if (m) {
      flush()
      out.push(line)
      open = { char: m[1][0], len: m[1].length }
    } else {
      chunk.push(line)
    }
  }
  flush()
  return out.join('\n')
}

/**
 * Applies `fn` to the text outside inline code spans, leaving the spans untouched. A span opens on a run of
 * backticks and closes on the nearest run of the same length in its paragraph (CommonMark), so a four-backtick run
 * inside a two-backtick span is text. An unpaired run is literal text, so one stray backtick never hides the rest of
 * the page from `fn`.
 */
export function outsideCodeSpans(text: string, fn: (chunk: string) => string): string {
  return text
    .split(/(\n[ \t]*\n)/)
    .map((part, i) => (i % 2 === 1 ? part : paragraphCodeSpans(part, fn)))
    .join('')
}

/** One paragraph: rewrites what sits between its inline code spans. */
function paragraphCodeSpans(paragraph: string, fn: (chunk: string) => string): string {
  const runs: { at: number; len: number }[] = []
  for (const run of paragraph.matchAll(/`+/g)) runs.push({ at: run.index ?? 0, len: run[0].length })
  const out: string[] = []
  let plainFrom = 0
  for (let open = 0; open < runs.length; open += 1) {
    const opener = runs[open]
    if (!opener) continue
    const closeAt = runs.findIndex((run, i) => i > open && run.len === opener.len)
    const closer = runs[closeAt]
    if (!closer) continue
    out.push(fn(paragraph.slice(plainFrom, opener.at)), paragraph.slice(opener.at, closer.at + closer.len))
    plainFrom = closer.at + closer.len
    open = closeAt
  }
  out.push(fn(paragraph.slice(plainFrom)))
  return out.join('')
}

export function stripVue(content: string): string {
  return outsideFences(content, (chunk) =>
    chunk
      .replace(/<script\b[\s\S]*?<\/script>\s*/g, '')
      .replace(/<style\b[\s\S]*?<\/style>\s*/g, '')
      .replace(/<!--\s*docs-sync:[^>]*-->\n?/g, ''),
  )
}

