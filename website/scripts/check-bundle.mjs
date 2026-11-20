#!/usr/bin/env node
/**
 * Bundle budgets, run after a build (scripts/build-site.sh):
 *   - the JavaScript each page loads up front, gzipped, stays under FIRST_LOAD_MAX_GZ (default 182 KB; framework code is about 160 KB of it);
 *   - no diagram library (mermaid, cytoscape, katex, dagre) ends up in the server bundle, which is the Cloudflare Worker.
 * Prints a table of the largest pages so a regression is easy to see.
 */
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { gzipSync } from 'node:zlib'

const root = path.resolve(import.meta.dirname, '..')
const next = path.join(root, '.next')
const max = Number(process.env.FIRST_LOAD_MAX_GZ ?? 182 * 1024)
const gz = (file) => gzipSync(readFileSync(file), { level: 6 }).length

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    e.isDirectory() ? walk(p, out) : out.push(p)
  }
  return out
}

if (!existsSync(path.join(next, 'server/app'))) {
  console.error('check-bundle: no .next build (run scripts/build-site.sh first)')
  process.exit(1)
}

const cache = new Map()
const size = (chunk) => cache.get(chunk) ?? (cache.set(chunk, gz(path.join(next, 'static', chunk))), cache.get(chunk))
const rows = []
for (const file of walk(path.join(next, 'server/app')).filter((f) => f.endsWith('.html') && !f.includes('_not-found') && !f.includes('/md/'))) {
  const html = readFileSync(file, 'utf8')
  const chunks = [...new Set([...html.matchAll(/\/_next\/static\/(chunks\/[^"']+?\.js)/g)].map((m) => m[1]))]
  rows.push({ page: path.relative(path.join(next, 'server/app'), file).replace(/\.html$/, ''), js: chunks.reduce((n, c) => n + size(c), 0), chunks: chunks.length, html: gzipSync(html).length })
}
rows.sort((a, b) => b.js - a.js)
console.log('first-load JS (gzip) per page, largest first:')
for (const r of rows.slice(0, 5)) console.log(`  ${(r.js / 1024).toFixed(1).padStart(7)} KB  ${String(r.chunks).padStart(2)} chunks  html ${(r.html / 1024).toFixed(1).padStart(5)} KB  /${r.page}`)
const over = rows.filter((r) => r.js > max)

const banned = /mermaid|cytoscape|katex|dagre/i
const leaked = walk(path.join(next, 'server')).filter((f) => banned.test(path.basename(f)) || (statSync(f).size > 20000 && f.endsWith('.js') && banned.test(readFileSync(f, 'utf8').slice(0, 2000)) && /node_modules/.test(f)))
if (over.length) console.error(`::error::${over.length} page(s) load more than ${(max / 1024).toFixed(0)} KB of JavaScript up front, e.g. /${over[0].page}: ${(over[0].js / 1024).toFixed(1)} KB`)
if (leaked.length) console.error(`::error::diagram libraries are in the server bundle (the Worker): ${leaked.slice(0, 3).map((f) => path.relative(root, f)).join(', ')}`)
process.exit(over.length || leaked.length ? 1 : 0)
