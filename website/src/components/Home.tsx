import Link from 'next/link'
import type { HomeData } from '../lib/content'
import { Banners } from './Banners'
import { LaunchVideo } from './LaunchVideo'
import { Logo } from './Logo'

const accents = ['a', 'b', 'a', 'b', 'a', 'b']

export function Home({ data }: { data: HomeData }) {
  const words = data.hero.text.split(/(?<=\.)\s+/)
  const last = words.pop()
  return (
    <>
      <section className="hero">
        <div className="orbits" aria-hidden>
          <i /> <i /> <i />
        </div>
        <p className="pill"><span className="dot" /> macOS fleet CI · open source · Apache-2.0</p>
        <h1>
          {words.join(' ')} <span className="accent">{last}</span>
        </h1>
        <p className="lead">{data.hero.tagline}</p>
        <div className="cta">
          {(data.hero.actions ?? []).filter((a) => a.link).map((a) => (
            <Link key={a.link} href={a.link} className={`btn ${a.theme === 'brand' ? 'btn-primary' : ''}`}>
              {a.text}
            </Link>
          ))}
        </div>
        {(data.install ?? []).length > 0 && (
          <div className="terminal">
            <div className="terminal-bar"><i /><i /><i /><span>up and running in three commands</span></div>
            <pre>
              {data.install.map((l, i) => (
                <span key={i}><b>$</b> {l}{'\n'}</span>
              ))}
              <em>✓ fleet online</em>
            </pre>
          </div>
        )}
      </section>

      <section className="section"><Banners /></section>

      <LaunchVideo />

      <section className="section" aria-labelledby="how-h">
        <p className="kicker">{'// HOW IT RUNS'}</p>
        <h2 id="how-h" className="section-h">Parallel jobs, not a queue.</h2>
        <div className="fleet">
          {[['FORGES', ['GitHub', 'GitLab', 'Gitea', 'Forgejo']], ['KINHIN', ['ephemeral', 'runners', 'autoscale']], ['JOBS', ['macOS · Tart', 'Linux · container', 'Docker · host']]].map(([title, items], i) => (
            <div key={title as string} className={`fleet-node ${i === 1 ? 'core' : ''}`}>
              <h3>{title}</h3>
              <ul>{(items as string[]).map((s) => <li key={s}>{s}</li>)}</ul>
            </div>
          ))}
          <span className="wire w1" aria-hidden><i /></span>
          <span className="wire w2" aria-hidden><i /></span>
        </div>
      </section>

      <section className="section" aria-labelledby="what-h">
        <p className="kicker">{'// WHAT YOU GET'}</p>
        <h2 id="what-h" className="sr-only">What you get</h2>
        <div className="features">
          {(data.features ?? []).map((f, i) => {
            const body = (
              <>
                <span className="icon"><Logo size={30} /></span>
                <h3>{f.title}</h3>
                <p>{f.details}</p>
                {f.link && <span className="more">{f.linkText ?? 'Read more'} →</span>}
              </>
            )
            // A release snapshot renders that release's own index.md, whose cards may have no link.
            return f.link ? (
              <Link key={f.title} href={f.link} className={`feature ${accents[i % 6]}`}>{body}</Link>
            ) : (
              <div key={f.title} className={`feature ${accents[i % 6]}`}>{body}</div>
            )
          })}
        </div>
      </section>

      <section className="section agents" aria-labelledby="agents-h">
        <div>
          <p className="kicker">{'// FOR AGENTS'}</p>
          <h2 id="agents-h" className="section-h">Every page is also markdown.</h2>
          <p className="muted">
            Ask for any URL with <code>Accept: text/markdown</code>, append <code>.md</code>, or start at <a href="/llms.txt">llms.txt</a>. Agent skills ship in the repo.{' '}
            <Link href="/guide/agents">AI agents &amp; MCP →</Link>
          </p>
        </div>
        <div className="terminal small">
          <pre>
            <span><b>$</b> curl -H &apos;Accept: text/markdown&apos; \{'\n'}</span>
            <span>    https://kinhin.dev/guide/quick-start{'\n'}</span>
            <em># Quick start …</em>
          </pre>
        </div>
      </section>

      {(data.questions ?? []).length > 0 && (
        <section className="section" aria-labelledby="faq-h">
        <p className="kicker">{'// COMMON QUESTIONS'}</p>
        <h2 id="faq-h" className="section-h">Answers before you try it.</h2>
        <div className="faq">
          {data.questions.map((q) => (
            <div key={q.group}>
              <h3>{q.group}</h3>
              <ul>{q.links.map((l) => <li key={l.href}><Link href={l.href}>{l.text}</Link></li>)}</ul>
            </div>
          ))}
        </div>
        </section>
      )}
    </>
  )
}
