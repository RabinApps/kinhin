import Link from 'next/link'
import { sponsors } from '../data/sponsors'
import { latestPost } from '../lib/content'
import { releaseVersion, stage } from '../lib/release'

/** The beta notice and the support/sponsor note under the hero (formerly HomeBanners.vue). */
export function Banners() {
  const heading = sponsors.length > 0 ? `Sponsored by ${sponsors.map((s) => s.name).join(', ')}` : 'Support kinhin'
  return (
    <div className="banners">
      <aside className="callout callout-warning">
        <div className="callout-title">{stage ? `${stage[0]}${stage.slice(1).toLowerCase()} (v${releaseVersion})` : `v${releaseVersion}`}</div>
        <p>
          Supports <strong>GitHub, Gitea, Forgejo and GitLab CE</strong>. See <Link href="/guide/forges#what-has-been-tested">what has been tested</Link>, the{' '}
          <Link href="/guide/beta-roadmap">roadmap</Link> and the <Link href={latestPost()}>{stage ? `${stage.toLowerCase()} announcement` : 'release announcement'}</Link>.{' '}
          <a href="https://github.com/RabinApps/kinhin/issues/new/choose">Report what you find</a>.
        </p>
      </aside>
      <aside className="callout callout-tip">
        <div className="callout-title">{heading}</div>
        {sponsors.length > 0 && (
          <p>
            kinhin is sponsored by{' '}
            {sponsors.map((sp, i) => (
              <span key={sp.name}>
                <a href={sp.url} target="_blank" rel="noopener sponsored">{sp.name}</a>, {sp.blurb.charAt(0).toLowerCase() + sp.blurb.slice(1)}
                {i < sponsors.length - 1 ? '; ' : ''}
              </span>
            ))}
            .
          </p>
        )}
        <p>
          kinhin is free and built by one developer: <Link href="/guide/support">donate or sponsor</Link>, or <Link href="/guide/used-by">add your project to the list</Link>.
        </p>
      </aside>
    </div>
  )
}
