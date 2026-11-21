/**
 * Security headers for every page the Worker serves (src/middleware.ts). Static files get the same set from public/_headers;
 * src/lib/headers.test.ts fails if the two drift.
 */
// Scripts: the theme bootstrap and Next's own payload are inline, hence 'unsafe-inline' (pages are prerendered, so there is no
// per-request nonce); markdown is sanitised at build time. Everything else is same-origin: the page makes no third-party calls.
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "media-src 'self'",
  "font-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ')

export const securityHeaders: Record<string, string> = {
  'content-security-policy': CSP,
  'strict-transport-security': 'max-age=31536000',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  'x-frame-options': 'DENY',
  'cross-origin-opener-policy': 'same-origin',
  'x-permitted-cross-domain-policies': 'none',
}
