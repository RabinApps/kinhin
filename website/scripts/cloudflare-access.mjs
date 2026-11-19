#!/usr/bin/env node
/**
 * Puts dev.kinhin.dev behind Cloudflare Access: creates (or updates) the Access application, an allow policy for your team,
 * and optionally a service token that CI uses to smoke-test the deployed site. Safe to re-run.
 *
 *   CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… \
 *     node scripts/cloudflare-access.mjs --email-domain example.com --service-token kinhin-ci-dev
 *     node scripts/cloudflare-access.mjs --emails a@example.com,b@example.com --dry-run
 *
 * Options
 *   --domain <host>             the hostname to protect (default dev.kinhin.dev)
 *   --email-domain <domain>     allow everyone at this email domain (repeatable)
 *   --emails <a,b>              allow these exact addresses
 *   --service-token <name>      create a service token with this name and a policy that lets it through (for CI)
 *   --rotate-service-token      with --service-token: rotate an existing token to get a new secret
 *   --session <duration>        session length (default 24h)
 *   --dry-run                   print what would be sent, call nothing
 *
 * The API token needs: Access: Apps and Policies Edit, Access: Service Tokens Edit, Access: Organizations, Identity Providers and
 * Groups Read. Nothing is stored: the values to keep are printed at the end.
 */
import { pathToFileURL } from 'node:url'

export function parseArgs(argv) {
  const o = { domain: 'dev.kinhin.dev', emails: [], emailDomains: [], serviceToken: undefined, rotate: false, session: '24h', dryRun: false }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => {
      const v = argv[++i]
      if (v === undefined || v.startsWith('--')) throw new Error(`${a} needs a value`)
      return v
    }
    if (a === '--domain') o.domain = next()
    else if (a === '--email-domain') o.emailDomains.push(next())
    else if (a === '--emails') o.emails.push(...next().split(',').map((e) => e.trim()).filter(Boolean))
    else if (a === '--service-token') o.serviceToken = next()
    else if (a === '--rotate-service-token') o.rotate = true
    else if (a === '--session') o.session = next()
    else if (a === '--dry-run') o.dryRun = true
    else throw new Error(`unknown option ${a}`)
  }
  if (!/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(o.domain)) throw new Error(`--domain must be a hostname, got "${o.domain}"`)
  if (o.emails.length === 0 && o.emailDomains.length === 0) throw new Error('say who may sign in: --email-domain <domain> and/or --emails <a,b>')
  for (const e of o.emails) if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) throw new Error(`not an email address: ${e}`)
  return o
}

export const appBody = (o) => ({ name: `kinhin ${o.domain}`, domain: o.domain, type: 'self_hosted', session_duration: o.session, app_launcher_visible: false })

/** The application to PUT: what is there now (identity providers, custom pages and so on, as edited in the dashboard) plus the fields this script manages. */
export const mergeApp = (existing, managed) => {
  const { id, uid, aud, created_at, updated_at, policies, ...editable } = existing
  return { ...editable, ...managed }
}

export const allowPolicyBody = (o) => ({
  name: 'Team',
  decision: 'allow',
  precedence: 1,
  include: [...o.emails.map((email) => ({ email: { email } })), ...o.emailDomains.map((domain) => ({ email_domain: { domain } }))],
})

export const servicePolicyBody = (tokenId) => ({ name: 'CI service token', decision: 'non_identity', precedence: 2, include: [{ service_token: { token_id: tokenId } }] })

async function main() {
  const o = parseArgs(process.argv.slice(2))
  const token = process.env.CLOUDFLARE_API_TOKEN
  const account = process.env.CLOUDFLARE_ACCOUNT_ID
  if (o.dryRun) {
    console.log(JSON.stringify({ application: appBody(o), policies: [allowPolicyBody(o), ...(o.serviceToken ? [servicePolicyBody('<token id>')] : [])], serviceToken: o.serviceToken ? { name: o.serviceToken, duration: '8760h', rotate: o.rotate } : undefined }, null, 2))
    console.log('\ndry run: nothing was sent')
    return
  }
  if (!token || !account) throw new Error('set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID')

  const api = `https://api.cloudflare.com/client/v4/accounts/${account}`
  async function cf(method, path, body) {
    const res = await fetch(api + path, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
    const json = await res.json().catch(() => ({}))
    if (!res.ok || json.success === false) throw new Error(`${method} ${path}: ${res.status} ${(json.errors ?? []).map((e) => e.message).join('; ')}`)
    return json.result
  }

  const org = await cf('GET', '/access/organizations')
  if (!org?.auth_domain) throw new Error('Zero Trust is not set up on this account yet: create a team domain in the Cloudflare dashboard first')

  const apps = await cf('GET', '/access/apps?per_page=100')
  let app = apps.find((a) => a.domain === o.domain)
  app = app ? await cf('PUT', `/access/apps/${app.id}`, mergeApp(app, appBody(o))) : await cf('POST', '/access/apps', appBody(o))
  console.log(`application ${app.id} for ${o.domain}`)

  const upsert = async (body) => {
    const existing = (await cf('GET', `/access/apps/${app.id}/policies`)).find((p) => p.name === body.name)
    return existing ? cf('PUT', `/access/apps/${app.id}/policies/${existing.id}`, body) : cf('POST', `/access/apps/${app.id}/policies`, body)
  }
  await upsert(allowPolicyBody(o))
  console.log('policy "Team" is in place')

  let secret
  if (o.serviceToken) {
    const tokens = await cf('GET', '/access/service_tokens?per_page=100')
    let st = tokens.find((t) => t.name === o.serviceToken)
    if (!st) st = await cf('POST', '/access/service_tokens', { name: o.serviceToken, duration: '8760h' })
    else if (o.rotate) st = await cf('POST', `/access/service_tokens/${st.id}/rotate`)
    secret = st.client_secret ? { id: st.client_id, secret: st.client_secret } : undefined
    if (!secret) console.log(`service token "${o.serviceToken}" already exists; its secret cannot be read again (re-run with --rotate-service-token for a new one)`)
    await upsert(servicePolicyBody(st.id))
    console.log('policy "CI service token" is in place')
  }

  console.log(`
Store these (GitHub repo → Settings → Secrets and variables → Actions):

  Variables
    DEV_ACCESS_TEAM_DOMAIN = ${org.auth_domain}
    DEV_ACCESS_AUD         = ${app.aud}
${secret ? `
  Secrets (shown once, copy them now)
    CF_ACCESS_CLIENT_ID     = ${secret.id}
    CF_ACCESS_CLIENT_SECRET = ${secret.secret}
` : ''}`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => {
    console.error(`cloudflare-access: ${e.message}`)
    process.exit(1)
  })
}
