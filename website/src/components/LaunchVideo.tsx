'use client'
import { useEffect, useState } from 'react'
import { withBase } from '../lib/base'

// The videos are optional drop-ins: put <name>.mp4 (and <name>.webm, <name>-poster.png) in website/public/
// (see docs/making-a-video.md). A video that is missing is left out, and with none the section shows nothing, so it
// never renders a broken player. The probe runs in the browser; failures (offline, 404, a non-video response) hide it.
const VIDEOS = [{ id: 'launch', label: 'What kinhin is' }]

const exists = async (url: string): Promise<boolean> => {
  try {
    const r = await fetch(url, { method: 'HEAD' })
    return r.ok && (r.headers.get('content-type') ?? '').startsWith('video/')
  } catch {
    return false
  }
}

export function LaunchVideo() {
  const [clips, setClips] = useState<typeof VIDEOS>([])
  const [on, setOn] = useState('launch')
  useEffect(() => {
    let live = true
    Promise.all(VIDEOS.map(async (v) => ((await exists(withBase(`/${v.id}.mp4`))) ? v : null))).then((r) => {
      const found = r.filter((v): v is (typeof VIDEOS)[number] => v !== null)
      if (live) {
        setClips(found)
        if (found[0]) setOn(found[0].id)
      }
    })
    return () => {
      live = false
    }
  }, [])
  if (!clips.length) return null
  return (
    <section className="section" aria-labelledby="video-h">
      <p className="kicker">{'// LAUNCH VIDEO'}</p>
      <h2 id="video-h" className="section-h">Rebuilt from your repo, every release.</h2>
      <div className="video-frame">
        {clips.length > 1 && (
          <div className="video-tabs" role="tablist">
            {clips.map((c) => (
              <button key={c.id} type="button" role="tab" aria-selected={on === c.id} className={on === c.id ? 'on' : ''} onClick={() => setOn(c.id)}>
                {c.label}
              </button>
            ))}
          </div>
        )}
        <video key={on} controls loop playsInline preload="metadata" poster={withBase(`/${on}-poster.png`)}>
          <source src={withBase(`/${on}.webm`)} type="video/webm" />
          <source src={withBase(`/${on}.mp4`)} type="video/mp4" />
          <a href={withBase(`/${on}.mp4`)}>Watch the kinhin video</a>
        </video>
      </div>
    </section>
  )
}
