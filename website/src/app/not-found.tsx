import Link from 'next/link'

export default function NotFound() {
  return (
    <section className="notfound">
      <div className="orbits" aria-hidden><i /> <i /> <i /></div>
      <p className="big">404</p>
      <h1>This runner went offline.</h1>
      <p className="lead">The page you asked for is gone, or never existed.</p>
      <div className="cta">
        <Link href="/guide/quick-start" className="btn btn-primary">Back to docs</Link>
        <Link href="/" className="btn">Home</Link>
      </div>
    </section>
  )
}
