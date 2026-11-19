import { defineCloudflareConfig } from '@opennextjs/cloudflare'
import staticAssetsIncrementalCache from '@opennextjs/cloudflare/overrides/incremental-cache/static-assets-incremental-cache'

// Every page is prerendered at build time and shipped as a static asset, so the Worker serves them from the
// ASSETS binding and never needs KV or R2. Nothing at request time reads the filesystem.
export default defineCloudflareConfig({ incrementalCache: staticAssetsIncrementalCache })
