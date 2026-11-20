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

const LIST_ITEM = /^[ \t]*(?:[-*+]|\d+[.)])[ \t]/
const HEADING = /^[ \t]*#{1,6}[ \t]/
const QUOTE = /^[ \t]*>/

/**
 * Where Markdown starts a new block: a blank line, a list item, a quote block, or either end of a one-line ATX
 * heading. Code spans cannot cross one (CommonMark), so neither can a pair of backticks in different blocks. A quote
 * continues in the same paragraph when its next line is quoted too, and a list item continues on an indented line, so
 * those keep the span open.
 */
function blockStarts(text: string): number[] {
  const starts: number[] = []
  let at = 0
  let quoted = false
  for (const line of text.split('\n')) {
    const quote = QUOTE.test(line)
    if (line.trim() === '') {
      starts.push(at)
      quoted = false
    } else if (LIST_ITEM.test(line)) {
      starts.push(at)
      quoted = quote
    } else if (HEADING.test(line)) {
      // A heading is one line: the paragraph under it starts on the next one.
      starts.push(at, at + line.length)
      quoted = quote
    } else if (quote && !quoted) {
      starts.push(at)
      quoted = true
    } else {
      quoted = quote
    }
    at += line.length + 1
  }
  return starts
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
  const starts = blockStarts(text)
  // The block of each run, as the number of boundaries before it: two runs share a block when this matches, so a
  // closer search never has to look at, or re-test, anything past the next boundary.
  const blocks: number[] = []
  let next = 0
  for (const run of runs) {
    while (next < starts.length && starts[next]! < run.at) next += 1
    blocks.push(next)
  }
  const spans: CodeSpan[] = []
  for (let open = 0; open < runs.length; open += 1) {
    const opener = runs[open]
    if (!opener || escaped(text, opener.at)) continue
    let closeAt = -1
    for (let i = open + 1; i < runs.length && blocks[i] === blocks[open]; i += 1) {
      if (runs[i]!.len === opener.len) {
        closeAt = i
        break
      }
    }
    const closer = runs[closeAt]
    if (!closer) continue
    spans.push({ from: opener.at, to: closer.at + closer.len })
    open = closeAt
  }
  return spans
}

// Apply a replacement until the text stops changing, so removing one tag cannot join the pieces around it into a new
// one (`<scr<script></script>ipt>`): a single pass leaves that behind, and CodeQL flags it as incomplete sanitization.
function replaceUntilStable(text: string, pattern: RegExp): string {
  let current = text
  for (;;) {
    const next = current.replace(pattern, '')
    if (next === current) return next
    current = next
  }
}

export function stripVue(content: string): string {
  return outsideFences(content, (chunk) =>
    replaceUntilStable(
      replaceUntilStable(
        replaceUntilStable(chunk, /<script\b[\s\S]*?<\/script\b[^>]*>\s*/gi),
        /<style\b[\s\S]*?<\/style\b[^>]*>\s*/gi,
      ),
      /<!--\s*docs-sync:[^>]*-->\n?/g,
    ),
  )
}

