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

export function stripVue(content: string): string {
  return outsideFences(content, (chunk) =>
    chunk
      .replace(/<script\b[\s\S]*?<\/script>\s*/g, '')
      .replace(/<style\b[\s\S]*?<\/style>\s*/g, '')
      .replace(/<!--\s*docs-sync:[^>]*-->\n?/g, ''),
  )
}

