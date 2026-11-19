import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { securityHeaders } from './headers.ts'

/** The `/*` block of public/_headers as { lowercase name: value }. */
function staticHeaders(): Record<string, string> {
  const out: Record<string, string> = {}
  let inAll = false
  for (const line of readFileSync(new URL('../../public/_headers', import.meta.url), 'utf8').split('\n')) {
    if (line.startsWith('#') || line.trim() === '') continue
    if (!line.startsWith(' ')) {
      inAll = line.trim() === '/*'
      continue
    }
    if (!inAll) continue
    const i = line.indexOf(':')
    out[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim()
  }
  return out
}

test('public/_headers carries every security header the middleware sends, with the same values', () => {
  const files = staticHeaders()
  for (const [name, value] of Object.entries(securityHeaders)) assert.equal(files[name], value, name)
})
