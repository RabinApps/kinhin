import assert from 'node:assert/strict'
import { test } from 'node:test'
import { accessToken, verifyAccessJwt, type AccessConfig, type Jwk } from './access.ts'

const cfg: AccessConfig = { teamDomain: 'team.cloudflareaccess.com', aud: 'aud-123' }
const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url')
const now = 1_800_000_000

async function setup() {
  const pair = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey('jwk', pair.publicKey)) as JsonWebKey
  const key: Jwk = { kid: 'k1', kty: 'RSA', n: jwk.n!, e: jwk.e! }
  const sign = async (claims: Record<string, unknown>, header: Record<string, unknown> = { alg: 'RS256', kid: 'k1' }) => {
    const body = `${enc(header)}.${enc(claims)}`
    const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', pair.privateKey, new TextEncoder().encode(body))
    return `${body}.${Buffer.from(sig).toString('base64url')}`
  }
  return { key, sign, keys: async () => [key] }
}
const good = { iss: 'https://team.cloudflareaccess.com', aud: ['aud-123'], exp: now + 600, email: 'dev@example.com' }

test('a valid Access token is accepted and names the user', async () => {
  const { sign, keys } = await setup()
  assert.deepEqual(await verifyAccessJwt(await sign(good), cfg, keys, now), { ok: true, email: 'dev@example.com' })
})

test('every way a token can be wrong is refused', async () => {
  const { sign, keys } = await setup()
  const reason = async (t: string | null) => ((await verifyAccessJwt(t, cfg, keys, now)) as { reason: string }).reason
  assert.equal(await reason(null), 'no token')
  assert.equal(await reason('a.b'), 'malformed token')
  assert.equal(await reason('x.y.z'), 'malformed token')
  assert.equal(await reason(await sign({ ...good, aud: ['other'] })), 'wrong audience')
  assert.equal(await reason(await sign({ ...good, iss: 'https://evil.cloudflareaccess.com' })), 'wrong issuer')
  assert.equal(await reason(await sign({ ...good, exp: now - 1 })), 'expired')
  assert.equal(await reason(await sign({ ...good, nbf: now + 3600 })), 'not yet valid')
  assert.equal(await reason(await sign(good, { alg: 'none', kid: 'k1' })), 'unsupported algorithm')
  assert.equal(await reason(await sign(good, { alg: 'RS256', kid: 'nope' })), 'unknown key')
})

test('a token signed by a different key is refused', async () => {
  const a = await setup()
  const b = await setup()
  const forged = await b.sign(good)
  assert.deepEqual(await verifyAccessJwt(forged, cfg, a.keys, now), { ok: false, reason: 'bad signature' })
})

test('an unknown key id triggers one refresh of the key set', async () => {
  const { sign, key } = await setup()
  const calls: boolean[] = []
  const rotated = async (refresh: boolean) => (calls.push(refresh), refresh ? [key] : [])
  assert.equal((await verifyAccessJwt(await sign(good), cfg, rotated, now)).ok, true)
  assert.deepEqual(calls, [false, true])
})

test('the token is read from the header, then the cookie', () => {
  assert.equal(accessToken(new Headers({ 'cf-access-jwt-assertion': 'h' })), 'h')
  assert.equal(accessToken(new Headers({ cookie: 'a=1; CF_Authorization=c.d.e; b=2' })), 'c.d.e')
  assert.equal(accessToken(new Headers()), null)
})
