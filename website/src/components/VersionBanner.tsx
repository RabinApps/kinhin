import { siteURL } from '../../site.config.ts'

/** Shown only on release snapshots, which are old docs for an old release. */
export function VersionBanner({ version }: { version: string }) {
  if (!version) return null
  return (
    <div className="version-banner" role="note">
      You are reading the docs for <strong>{version}</strong>. <a href={`${siteURL}/`}>Latest (main) →</a>
    </div>
  )
}
