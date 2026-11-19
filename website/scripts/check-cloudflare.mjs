#!/usr/bin/env node
/**
 * Does the Cloudflare token + account id used by the Docs workflow actually work for this deploy? Calls the Cloudflare API
 * read-only and prints one line per check. Nothing is changed and no secret is printed.
 *
 *   CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… node scripts/check-cloudflare.mjs
 *   node scripts/check-cloudflare.mjs --zone kinhin.dev --hosts kinhin.dev,dev.kinhin.dev
 *
 * Also runs in CI: Actions → "Cloudflare check" → Run workflow (it uses the repository secrets).
 * Exit status is 1 when a required check fails; warnings (for example an existing DNS record that blocks attaching a custom
 * domain) do not fail it.
 */
import { pathToFileURL } from 'node:url'

export function parseArgs(argv) {
  const o = { zone: 'kinhin.dev', hosts: ['kinhin.dev', 'dev.kinhin.dev'] }
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i + 1]
    if (argv[i] === '--zone' && v) (o.zone = v), i++
    else if (argv[i] === '--hosts' && v) (o.hosts = v.split(',').map((h) => h.trim()).filter(Boolean)), i++
    else throw new Error(`unknown option ${argv[i]}`)
  }
  return o
}

/** What an existing DNS record means for attaching a Workers custom domain at that hostname. */
export function dnsVerdict(host, records) {
  const blocking = records.filter((r) => ['A', 'AAAA', 'CNAME'].includes(r.type))
  if (blocking.length === 0) return { level: 'ok', text: `${host}: no A/AAAA/CNAME record, a Workers custom domain can be attached` }
  const what = blocking.map((r) => `${r.type} → ${r.content}`).join(', ')
  return { level: 'warn', text: `${host}: has ${what}. Cloudflare refuses to attach a Workers custom domain over an existing record: remove it right before the first deploy (the site is unreachable until the deploy finishes)` }
}

async function main() {
  const o = parseArgs(process.argv.slice(2))
  const token = process.env.CLOUDFLARE_API_TOKEN
  const account = process.env.CLOUDFLARE_ACCOUNT_ID
  let failed = false
  const say = (level, text) => {
    if (level === 'fail') failed = true
    console.log(`${{ ok: 'ok  ', warn: 'WARN', fail: 'FAIL' }[level]} ${text}`)
  }
  if (!token) return say('fail', 'CLOUDFLARE_API_TOKEN is not set (in CI: the repository secret of that exact name)'), process.exit(1)
  if (!account) say('fail', 'CLOUDFLARE_ACCOUNT_ID is not set (in CI: the repository secret of that exact name)')
  else if (!/^[0-9a-f]{32}$/i.test(account)) say('fail', 'CLOUDFLARE_ACCOUNT_ID should be 32 hexadecimal characters (stray spaces or a newline? it is the account id, not the account name)')

  const call = async (path) => {
    const res = await fetch(`https://api.cloudflare.com/client/v4${path}`, { headers: { authorization: `Bearer ${token}` } })
    const json = await res.json().catch(() => ({}))
    return { ok: res.ok && json.success !== false, status: res.status, result: json.result, error: (json.errors ?? []).map((e) => e.message).join('; ') }
  }
  const probe = async (label, path, needs) => {
    const r = await call(path)
    if (r.ok) say('ok', `${label}`)
    else say('fail', `${label}: ${r.status} ${r.error}${needs ? ` (the token needs: ${needs})` : ''}`)
    return r
  }

  const verify = await call('/user/tokens/verify')
  if (!verify.ok || verify.result?.status !== 'active') {
    say('fail', `the token is not valid or not active (${verify.status} ${verify.error || verify.result?.status || ''})`)
    return process.exit(1)
  }
  say('ok', 'the token is valid and active')

  if (account) {
    await probe('the account id is reachable with this token', `/accounts/${account}`, 'Account Settings: Read')
    await probe('Workers scripts can be listed', `/accounts/${account}/workers/scripts`, 'Workers Scripts: Edit')
  }
  const zones = await call(`/zones?name=${encodeURIComponent(o.zone)}`)
  const zone = zones.result?.[0]
  if (!zones.ok || !zone) return say('fail', `zone ${o.zone} is not visible to this token (Zone: Read, scoped to that zone)`), process.exit(1)
  if (account && zone.account?.id && zone.account.id !== account) say('fail', `zone ${o.zone} belongs to a different account than CLOUDFLARE_ACCOUNT_ID`)
  else say('ok', `zone ${o.zone} is on this account (status ${zone.status})`)
  await probe('Workers routes can be read', `/zones/${zone.id}/workers/routes`, 'Workers Routes: Edit')
  for (const host of o.hosts) {
    const dns = await call(`/zones/${zone.id}/dns_records?name=${encodeURIComponent(host)}`)
    if (!dns.ok) say('fail', `DNS records of ${host} cannot be read: ${dns.status} ${dns.error} (the token needs: Zone DNS: Edit)`)
    else {
      const v = dnsVerdict(host, dns.result ?? [])
      say(v.level, v.text)
    }
  }
  console.log(failed ? '\nsome required checks failed' : '\nthe token and account id look right for the deploy')
  process.exit(failed ? 1 : 0)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch((e) => (console.error(`check-cloudflare: ${e.message}`), process.exit(1)))
