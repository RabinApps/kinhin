import assert from 'node:assert/strict'
import { test } from 'node:test'
import { dnsVerdict, parseArgs } from './check-cloudflare.mjs'

test('options', () => {
  assert.deepEqual(parseArgs([]), { zone: 'kinhin.dev', hosts: ['kinhin.dev', 'dev.kinhin.dev'] })
  assert.deepEqual(parseArgs(['--zone', 'x.dev', '--hosts', 'a.x.dev, b.x.dev']), { zone: 'x.dev', hosts: ['a.x.dev', 'b.x.dev'] })
  assert.throws(() => parseArgs(['--bogus']), /unknown option/)
})

test('an existing A or CNAME record blocks a custom domain, other records do not', () => {
  assert.equal(dnsVerdict('kinhin.dev', []).level, 'ok')
  assert.equal(dnsVerdict('kinhin.dev', [{ type: 'TXT', content: 'x' }, { type: 'MX', content: 'mail' }]).level, 'ok')
  const v = dnsVerdict('kinhin.dev', [{ type: 'A', content: '185.199.108.153' }, { type: 'CNAME', content: 'rabinapps.github.io' }])
  assert.equal(v.level, 'warn')
  assert.match(v.text, /A → 185\.199\.108\.153/)
})
