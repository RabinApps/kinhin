import { releaseVersion } from '../data/release.ts'

export { releaseVersion }

/** `BETA`, `ALPHA` or `RC` for a prerelease (`0.0.1-beta-7`), `null` for a stable version (`0.1.0`). */
export function releaseStage(version: string): 'BETA' | 'ALPHA' | 'RC' | null {
  const m = /-(alpha|beta|rc)(?![a-z])/i.exec(version)
  return m ? (m[1].toUpperCase() as 'BETA' | 'ALPHA' | 'RC') : null
}

/** The stage of the release the site documents: drives the header badge and the home banner, so shipping 0.1.0 needs no code edit. */
export const stage = releaseStage(releaseVersion)
