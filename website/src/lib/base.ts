/** Prefix for plain `<img>`/`<a>`/fetch URLs inside a release snapshot (next/link adds it by itself). */
export const BASE = process.env.NEXT_PUBLIC_BASE_PATH ?? ''
export const withBase = (p: string): string => (p.startsWith('/') && !p.startsWith('//') ? BASE + p : p)
export const DOCS_VERSION = process.env.NEXT_PUBLIC_DOCS_VERSION ?? ''
