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

/** A range of text held inside an inline code span, from its opening backticks to the end of its closing run. */
export interface CodeSpan {
  from: number
  to: number
}

const BLOCK_START = /\n[ \t]*\n|\n[ \t]*(?=[-*+][ \t]|\d+[.)][ \t]|#{1,6}[ \t]|>)/g

/**
 * Where Markdown starts a new block: a blank line, or a line that opens a list item, heading or quote. Code spans
 * cannot cross one (CommonMark), so neither can a pair of backticks in different blocks.
 */
function blockStarts(text: string): number[] {
  return [...text.matchAll(BLOCK_START)].map((m) => m.index ?? 0)
}

/** True when the backtick run at `at` is backslash-escaped, and so is a literal character rather than an opener. */
function escaped(text: string, at: number): boolean {
  let backslashes = 0
  while (text[at - backslashes - 1] === '\\') backslashes += 1
  return backslashes % 2 === 1
}

/**
 * The inline code spans of `text`, in document order. A run of backticks closes on the nearest later run of the same
 * length in the same block, so a four-backtick run inside a two-backtick span is text. An escaped run, or one with
 * no partner, is literal: a lone backtick never hides the markdown after it.
 */
export function codeSpans(text: string): CodeSpan[] {
  const runs: { at: number; len: number }[] = []
  for (const run of text.matchAll(/`+/g)) runs.push({ at: run.index ?? 0, len: run[0].length })
  const blocks = blockStarts(text)
  const spans: CodeSpan[] = []
  for (let open = 0; open < runs.length; open += 1) {
    const opener = runs[open]
    if (!opener || escaped(text, opener.at)) continue
    const closeAt = runs.findIndex(
      (run, i) => i > open && run.len === opener.len && !blocks.some((b) => b > opener.at && b < run.at),
    )
    const closer = runs[closeAt]
    if (!closer) continue
    spans.push({ from: opener.at, to: closer.at + closer.len })
    open = closeAt
  }
  return spans
}

export function stripVue(content: string): string {
  return outsideFences(content, (chunk) =>
    chunk
      .replace(/<script\b[\s\S]*?<\/script>\s*/g, '')
      .replace(/<style\b[\s\S]*?<\/style>\s*/g, '')
      .replace(/<!--\s*docs-sync:[^>]*-->\n?/g, ''),
  )
}

