import assert from 'node:assert/strict'
import { test } from 'node:test'
import { allowPolicyBody, appBody, mergeApp, parseArgs, servicePolicyBody } from './cloudflare-access.mjs'

test('options are parsed and validated', () => {
  const o = parseArgs(['--email-domain', 'example.com', '--emails', 'a@x.io, b@y.io', '--service-token', 'ci', '--dry-run'])
  assert.deepEqual([o.domain, o.emailDomains, o.emails, o.serviceToken, o.dryRun, o.session], ['dev.kinhin.dev', ['example.com'], ['a@x.io', 'b@y.io'], 'ci', true, '24h'])
  assert.throws(() => parseArgs([]), /who may sign in/)
  assert.throws(() => parseArgs(['--emails', 'not-an-email']), /not an email/)
  assert.throws(() => parseArgs(['--email-domain', 'x.com', '--domain', 'nope']), /hostname/)
  assert.throws(() => parseArgs(['--email-domain']), /needs a value/)
  assert.throws(() => parseArgs(['--email-domain', 'x.com', '--bogus']), /unknown option/)
})

test('the application and policies have the shape the API expects', () => {
  const o = parseArgs(['--email-domain', 'example.com', '--emails', 'a@x.io'])
  const app = appBody(o)
  assert.equal(app.type, 'self_hosted')
  assert.equal(app.domain, 'dev.kinhin.dev')
  assert.equal(app.session_duration, '24h')
  assert.deepEqual(allowPolicyBody(o).include, [{ email: { email: 'a@x.io' } }, { email_domain: { domain: 'example.com' } }])
  assert.equal(allowPolicyBody(o).decision, 'allow')
  assert.deepEqual(servicePolicyBody('tok'), { name: 'CI service token', decision: 'non_identity', precedence: 2, include: [{ service_token: { token_id: 'tok' } }] })
})

test('re-running keeps what was edited in the dashboard and drops read-only fields', () => {
  const o = parseArgs(['--email-domain', 'example.com'])
  const existing = { id: 'x', uid: 'u', aud: 'a', created_at: 't', updated_at: 't', policies: [], domain: 'old.example', allowed_idps: ['idp-1'], custom_deny_message: 'nope', session_duration: '1h' }
  const merged = mergeApp(existing, appBody(o))
  assert.deepEqual([merged.allowed_idps, merged.custom_deny_message], [['idp-1'], 'nope'])
  assert.deepEqual([merged.domain, merged.session_duration], ['dev.kinhin.dev', '24h'])
  for (const k of ['id', 'uid', 'aud', 'created_at', 'updated_at', 'policies']) assert.equal(k in merged, false, k)
})
