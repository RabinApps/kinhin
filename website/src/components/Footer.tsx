import Link from 'next/link'
import { footer } from '../../site.config.ts'
import { Logo } from './Logo'

export function Footer() {
  return (
    <footer className="site-footer">
      <div className="site-footer-in">
        <div className="brand">
          <Logo size={28} />
          <span>kinhin</span>
        </div>
        <p>{footer.license}</p>
        <p className="footer-links">
          {footer.links.map((l, i) => (
            <span key={l.href}>
              {i > 0 && ' · '}
              {l.href.startsWith('http') ? <a href={l.href}>{l.text}</a> : <Link href={l.href}>{l.text}</Link>}
            </span>
          ))}
        </p>
        <p className="muted">{footer.copyright} · <a href="/llms.txt">llms.txt</a></p>
      </div>
    </footer>
  )
}
