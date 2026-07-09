import { OpenPanel } from '@openpanel/web'

const CLIENT_ID = '6384a959-04c7-4a85-9472-3fd0ad3079dd'
const API_URL = 'https://openpanel.nightly.app/api'

let op: OpenPanel | null = null

// Idempotent; safe to call on every mount. No-op on the server (the SDK touches
// window/document, and this app SSRs on a Cloudflare Worker).
export function initOpenPanel() {
  if (typeof window === 'undefined' || op) return op
  op = new OpenPanel({
    clientId: CLIENT_ID,
    apiUrl: API_URL,
    trackScreenViews: true, // SPA pageviews via the History API (TanStack Router)
    trackOutgoingLinks: true, // external link clicks
    trackAttributes: true, // enables data-track="…" click tracking
  })
  return op
}

export function track(name: string, props?: Record<string, unknown>) {
  op?.track(name, props)
}
