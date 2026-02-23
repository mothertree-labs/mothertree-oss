# Cloudflare CDN Caching Setup

This project uses Cloudflare proxy (orange cloud) in production. Origin servers set `Cache-Control` headers, but Cloudflare also needs Cache Rules configured via the dashboard for optimal behavior.

## What the origin does

### Cached (immutable static assets)

| App | Path | Header | Why safe |
|-----|------|--------|----------|
| Element Web | `/bundles/` | `public, max-age=31536000, immutable` | Webpack content-hashed filenames |
| Docs Frontend | `/_next/static/` | `public, max-age=31536000, immutable` | Next.js content-hashed filenames |
| Jitsi Meet | `/libs/`, `/css/`, etc. | `Expires: 1y` (when `?v=` present) | Version-parameterized URLs |
| Home Portal | static file extensions | `public, immutable` + `Expires: 1y` | Static HTML/CSS/JS page |

Cache invalidation is automatic on upgrade — new image tags produce new content-hashed filenames.

### Not cached (safety rails)

These ingresses explicitly set `Cache-Control: no-store` to prevent Cloudflare from ever caching sensitive responses:

| Service | Content protected |
|---------|-------------------|
| Synapse | Matrix API — messages, user data, auth tokens |
| Keycloak | Login pages, OIDC tokens, session data |
| Admin Portal | Server-rendered admin pages with session data |
| Account Portal | Server-rendered user account pages |
| Stalwart | JMAP API, email content, webmail interface |
| Docs (main) | API responses, media uploads, collaboration data |

### Not yet cached (deferred)

| App | Reason |
|-----|--------|
| Nextcloud | PHP sets `Set-Cookie` on all responses, blocking Cloudflare caching |
| Roundcube | Same PHP cookie issue + session affinity + risk of caching email content |

## Cloudflare Dashboard: Cache Rules

Go to **Cloudflare Dashboard > [your zone] > Caching > Cache Rules** and create these rules in order:

### Rule 1: Bypass cache on auth/admin/mail subdomains

- **Name**: `Bypass sensitive subdomains`
- **When**: `http.host contains "auth." or http.host contains "admin." or http.host contains "account." or http.host contains "mail."`
- **Then**: **Bypass cache**

### Rule 2: Bypass cache on Matrix API paths

- **Name**: `Bypass Matrix API`
- **When**: `http.request.uri.path contains "/_matrix/" or http.request.uri.path contains "/_synapse/"`
- **Then**: **Bypass cache**

### Rule 3: Cache static assets using origin headers

- **Name**: `Cache static assets`
- **When**: `http.request.uri.path.extension in {"js" "css" "woff" "woff2" "ttf" "eot" "svg" "png" "jpg" "jpeg" "gif" "ico" "map"}`
- **Then**:
  - Cache eligibility: **Eligible for cache**
  - Edge TTL: **Respect origin**
  - Browser TTL: **Respect origin**

### Rule order

Rules are evaluated top-to-bottom, first match wins. Put bypass rules before the cache rule so sensitive paths are never cached even if they serve `.js` or `.css` files.

## Verification

After deploying origin changes and configuring Cloudflare rules:

```bash
# Static assets — should show CF-Cache-Status: HIT (after second request)
curl -sI https://matrix.<domain>/bundles/<hash>/bundle.js | grep -iE "cache-control|cf-cache-status"
# Expected: cache-control: public, max-age=31536000, immutable
# Expected: cf-cache-status: HIT

# Matrix API — should never be cached
curl -sI https://matrix.<domain>/_matrix/client/versions | grep -iE "cache-control|cf-cache-status"
# Expected: cache-control: no-store
# Expected: cf-cache-status: DYNAMIC

# Auth — should never be cached
curl -sI https://auth.<domain>/ | grep -iE "cache-control|cf-cache-status"
# Expected: cache-control: no-store
# Expected: cf-cache-status: BYPASS or DYNAMIC
```

Dev environments use DNS-only (grey cloud) so `CF-Cache-Status` won't appear there. Verify origin headers only:

```bash
curl -sI https://matrix.dev.<domain>/bundles/<hash>/file.js | grep -i cache-control
# Expected: cache-control: public, max-age=31536000, immutable
```
