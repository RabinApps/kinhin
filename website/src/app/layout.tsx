import type { Metadata, Viewport } from 'next'
import { GeistMono } from 'geist/font/mono'
import { GeistSans } from 'geist/font/sans'
import { siteDescription, siteURL } from '../../site.config.ts'
import { Footer } from '../components/Footer'
import { Header } from '../components/Header'
import { Search } from '../components/Search'
import { VersionBanner } from '../components/VersionBanner'
import { getManifest } from '../lib/content'
import './globals.css'
import '../../.generated/shiki.css'

export const metadata: Metadata = {
  metadataBase: new URL(siteURL),
  title: { default: 'kinhin: Your Mac is your CI', template: '%s · kinhin' },
  description: siteDescription,
  icons: { icon: [{ url: '/favicon.ico', sizes: 'any' }, { url: '/favicon.svg', type: 'image/svg+xml' }, { url: '/favicon-32.png', sizes: '32x32', type: 'image/png' }], apple: '/apple-touch-icon.png' },
  alternates: { types: { 'application/atom+xml': '/blog/feed.xml' } },
  applicationName: 'kinhin',
  authors: [{ name: 'Rabin Apps, LLC' }],
  creator: 'Rabin Apps, LLC',
  robots: { index: true, follow: true, googleBot: { index: true, follow: true, 'max-image-preview': 'large', 'max-snippet': -1, 'max-video-preview': -1 } },
}
export const viewport: Viewport = {
  themeColor: [{ media: '(prefers-color-scheme: dark)', color: '#05060A' }, { media: '(prefers-color-scheme: light)', color: '#F6F7FB' }],
  colorScheme: 'dark light',
  viewportFit: 'cover',
}

const themeScript = `try{var t=localStorage.getItem('kinhin:theme');if(t)document.documentElement.dataset.theme=t}catch(e){}`

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const m = getManifest()
  return (
    <html lang="en" className={`${GeistSans.variable} ${GeistMono.variable}`} suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>
        <a href="#main" className="skip">Skip to content</a>
        <VersionBanner version={m.version} />
        <Header versions={m.versions} stars={m.stars} />
        <main id="main">{children}</main>
        <Footer />
        <Search />
      </body>
    </html>
  )
}
