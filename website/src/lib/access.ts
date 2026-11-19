/**
 * Cloudflare Access: verifying the JWT Access puts on every request it lets through (the `Cf-Access-Jwt-Assertion` header).
 * Access already blocks anonymous visitors at the edge; checking the token again in the Worker means the dev site stays closed
 * even if the Access application is deleted, disabled or pointed at the wrong hostname.
 * https://developers.cloudflare.com/cloudflare-one/identity/authorization-cookie/validating-json/
 */
export interface AccessConfig {
  /** `<team>.cloudflareaccess.com` */
  teamDomain: string
  /** The Access application's audience (AUD) tag. */
  aud: string
}
export interface Jwk {
  kid: string
  kty: string
  n: string
  e: string
}
export type AccessResult = { ok: true; email?: string } | { ok: false; reason: string }

function b64(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '='))
  const out = new Uint8Array(new ArrayBuffer(bin.length))
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
const json = (s: string): any => JSON.parse(new TextDecoder().decode(b64(s)))

export async function verifyAccessJwt(token: string | null | undefined, cfg: AccessConfig, getKeys: (refresh: boolean) => Promise<Jwk[]>, now = Date.now() / 1000): Promise<AccessResult> {
  if (!token) return { ok: false, reason: 'no token' }
  const parts = token.split('.')
  if (parts.length !== 3) return { ok: false, reason: 'malformed token' }
  let header: any, payload: any
  try {
    header = json(parts[0])
    payload = json(parts[1])
  } catch {
    return { ok: false, reason: 'malformed token' }
  }
  if (header.alg !== 'RS256') return { ok: false, reason: 'unsupported algorithm' }
  if (payload.iss !== `https://${cfg.teamDomain}`) return { ok: false, reason: 'wrong issuer' }
  const aud: unknown = payload.aud
  if (!(Array.isArray(aud) ? aud.includes(cfg.aud) : aud === cfg.aud)) return { ok: false, reason: 'wrong audience' }
  if (typeof payload.exp !== 'number' || payload.exp <= now) return { ok: false, reason: 'expired' }
  if (typeof payload.nbf === 'number' && payload.nbf > now + 60) return { ok: false, reason: 'not yet valid' }

  // The signing keys rotate: an unknown key id is retried once with a fresh key set.
  let jwk = (await getKeys(false)).find((k) => k.kid === header.kid)
  if (!jwk) jwk = (await getKeys(true)).find((k) => k.kid === header.kid)
  if (!jwk) return { ok: false, reason: 'unknown key' }
  const key = await crypto.subtle.importKey('jwk', { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true }, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify'])
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`))
  return valid ? { ok: true, email: typeof payload.email === 'string' ? payload.email : undefined } : { ok: false, reason: 'bad signature' }
}

/** The token from the request: Access sends it as a header and also sets it as the `CF_Authorization` cookie. */
export function accessToken(headers: Headers): string | null {
  const h = headers.get('cf-access-jwt-assertion')
  if (h) return h
  const m = /(?:^|;\s*)CF_Authorization=([^;]+)/.exec(headers.get('cookie') ?? '')
  return m ? m[1] : null
}

let cache: { domain: string; keys: Jwk[]; at: number } | undefined
let lastRefresh = 0

/** Forced refreshes (an unknown key id) are spaced at least this far apart, so bad tokens cannot make the Worker hammer the endpoint. */
export const REFRESH_INTERVAL_MS = 60_000

/** The team's public signing keys, cached for an hour (and refreshed on demand, at most once a minute, when a key id is unknown). */
export async function fetchAccessKeys(teamDomain: string, refresh: boolean, fetcher: typeof fetch = fetch, now = Date.now()): Promise<Jwk[]> {
  const fresh = cache && cache.domain === teamDomain
  if (fresh && !refresh && now - cache!.at < 3_600_000) return cache!.keys
  if (fresh && refresh && now - lastRefresh < REFRESH_INTERVAL_MS) return cache!.keys
  const res = await fetcher(`https://${teamDomain}/cdn-cgi/access/certs`)
  if (!res.ok) throw new Error(`Access keys: HTTP ${res.status}`)
  const keys = ((await res.json()) as { keys: Jwk[] }).keys
  cache = { domain: teamDomain, keys, at: now }
  lastRefresh = now
  return keys
}

/** For tests: forget the cached keys. */
export function resetAccessKeyCache(): void {
  cache = undefined
  lastRefresh = 0
}
