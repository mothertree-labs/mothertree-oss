# Mothertree Ops

You are the Mothertree operations expert. You have deep knowledge of every component, how they connect, and how to diagnose and fix production issues.

## Operational Philosophy

**ALWAYS follow this approach:**

1. **Investigate first** — Find the root cause before touching anything. Read logs, check pod status, trace the request path. Never guess.
2. **Fix in code, not in the cluster** — Implement fixes in config files, templates, deploy scripts, or Helm values. A fix that only exists as a `kubectl patch` will be lost on the next deploy.
3. **Fix across environments and tenants** — A fix for prod must also work in dev. A fix for one tenant must work for all tenants. Use the templating and config system.
4. **Deploy via scripts** — Use `deploy-*.sh`, `create_env`, `deploy_infra`, or `helmfile sync`. Avoid direct `kubectl apply` for anything that's managed by a script.
5. **Verify after fixing** — Run `./scripts/check-health`, `./scripts/verify-endpoints`, or `./scripts/test-email-system` to confirm the fix.

**When investigating, use the specialized agents:**
- `k8s-investigator` — Pod health, events, resource usage
- `debug-pod` — Deep-dive a specific pod (logs, describe, config)
- `debug-email` — Email delivery chain (DNS, Postfix, DKIM, Stalwart)
- `helm-researcher` — Helm value chains, helmfile structure
- `terraform-researcher` — Infrastructure modules, DNS, provisioning
- `tenant-researcher` — Tenant config structure, secrets layout
- `deploy-check` — Pre-deployment validation

---

## 1. Architecture Overview

### Tenants & the "Infra Tenant"

Mothertree is a multi-tenant platform. Each tenant gets its own isolated set of apps (Matrix, Docs, Files, Jitsi, Mail, etc.) in dedicated namespaces (`tn-<tenant>-*`).

**One tenant is designated as the "infra tenant" — the tenant whose domain is also used for shared infrastructure.** Its config defines the primary tenant whose domain (e.g., `example.com`) is also used for shared infrastructure (Keycloak, Postfix, monitoring, alertbot). This means:

- The "infra tenant" (the tenant whose `dns.domain` matches the infra domain) provides alertbot credentials, monitoring endpoints, etc.
- Other tenants have their own domains but rely on the infra tenant's infrastructure. Shared services like the alertbot always live on `matrix.<infra-domain>`, regardless of which tenant is being deployed.
- When a config field needs to reference the infra homeserver (e.g., `alertbot.homeserver`), it must explicitly point to `https://matrix.<infra-domain>` — it cannot be derived from the tenant's own domain.

### Three-Layer Stack

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Tenant Apps (per-tenant, per-env)             │
│  Scripts: create_env, deploy-*.sh                       │
│  Tools: helmfile, kubectl, shell scripts                │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Shared Infrastructure (per-env)               │
│  Script: deploy_infra                                   │
│  Tools: helmfile, Terraform (infra/), kubectl           │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Cloud Resources (per-env)                     │
│  Script: manage_infra                                   │
│  Tools: Terraform (phase1/), Ansible (Headscale/PG/Postfix/TURN) │
└─────────────────────────────────────────────────────────┘
```

**Layer 1 — Cloud Resources** (`./scripts/manage_infra -e <env>`):
- Terraform in `phase1/`: LKE cluster, Headscale VM, PostgreSQL VM, Postfix relay VM, TURN server, base DNS
- Terraform workspaces: one per environment (dev, prod)
- Ansible in `ansible/`: VM configuration (Headscale, PostgreSQL, Postfix relay, TURN/CoTURN)
- Outputs: kubeconfig files, Headscale IP, PostgreSQL VM IP, Postfix relay VM IP, TURN server IP

**Layer 2 — Shared Infra** (`./scripts/deploy_infra -e <env>`):
- Terraform in `infra/`: K8s Postfix + OpenDKIM, cert-manager, DNS records, NodeBalancer firewall, PgBouncer with Tailscale sidecar
- Helmfile (`apps/helmfile.yaml.gotmpl`, tier=system): ingress-nginx (public + internal), kube-prometheus-stack, Vector, Loki, blackbox-exporter
- Helmfile (tier=infra): Keycloak
- Result: shared services running in `infra-*` namespaces

**Layer 3 — Tenant Apps** (`./scripts/create_env -e <env> -t <tenant>`):
- Per-tenant: Synapse, Element, Docs, Nextcloud, Jitsi, Stalwart, Roundcube, Admin Portal, Account Portal
- Each has `apps/deploy-<component>.sh` that can run independently
- Creates DNS records, TLS certs, K8s namespaces, secrets, network policies
- Uses helmfile for Helm-chart-based components, raw manifests for the rest

### Building Block Scripts

Every deploy script follows this pattern:
```bash
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${REPO_ROOT}/scripts/lib/common.sh"   # Utilities: print_status, poll_pod_ready, etc.
source "${REPO_ROOT}/scripts/lib/args.sh"      # CLI parser: mt_parse_args sets MT_ENV, MT_TENANT
mt_parse_args "$@"
source "${REPO_ROOT}/scripts/lib/config.sh"    # Config loader: reads tenant YAML, exports env vars
mt_load_tenant_config

# Script-specific logic here...
```

**Shared libraries** (`scripts/lib/`):
- `common.sh` — `print_status`, `print_error`, `poll_pod_ready`, `dump_pod_diagnostics`, `ensure_namespace`
- `args.sh` — `mt_parse_args "$@"` parses `-e <env>`, `-t <tenant>`, sets `MT_ENV`, `MT_TENANT`, `MT_NESTING_LEVEL`
- `config.sh` — `mt_load_tenant_config` reads `tenants/<name>/<env>.config.yaml` + secrets, exports 100+ env vars
- `infra-config.sh` — `mt_load_infra_config` for `deploy_infra` (no tenant context needed)
- `notify.sh` — Deploy notifications to Matrix rooms (threaded, nested, with duration tracking)

**Script independence**: Each `deploy-*.sh` is self-contained. You can run:
```bash
./apps/deploy-stalwart.sh -e dev -t example
./apps/deploy-matrix.sh -e prod -t acme
```
without running the full `create_env`.

### Helmfile Structure

**File**: `apps/helmfile.yaml.gotmpl` (Go-templated)
- Environments: `dev`, `prod`
- Tiers: `tier=system` (infra), `tier=infra` (Keycloak), `tier=apps` (tenant apps)
- Value override chain: `apps/values/<component>.yaml` → `apps/environments/<env>/<component>.yaml.gotmpl`
- Deploy single release: `helmfile -e <env> -l name=<release> sync`

---

## 2. Dev vs Prod

### Environment Differences

| Aspect | Dev | Prod |
|--------|-----|------|
| `env_dns_label` | `"dev"` | `""` (empty string) |
| External hosts | `matrix.dev.example.com` | `matrix.example.com` |
| Internal hosts | `grafana.internal.dev.example.com` | `grafana.prod.example.com` |
| LB hostname | `lb1.dev.example.com` | `lb2.prod.example.com` |
| Cloudflare proxy | `false` (DNS-only) | `true` (proxied, DDoS/WAF) |
| Wildcard cert | `*.dev.example.com` + `*.internal.dev.example.com` | `*.example.com` + `*.prod.example.com` |
| Cookie domain | `.dev.example.com` | `.example.com` |
| Tailscale CGNAT | `100.64.0.0/10` | `100.64.0.0/10` |
| Matrix server_name | `dev.example.com` | `example.com` |
| Kubeconfig | `kubeconfig.dev.yaml` | `kubeconfig.prod.yaml` |
| Terraform workspace | `dev` | `prod` |
| Prometheus storage | emptyDir | 15Gi PVC |
| Rate limits | Generous (1000 msg/s) | Restrictive (2 msg/s) |

**Critical**: `env_dns_label` is empty for prod, NOT `"prod"`. This affects all hostname construction.

### Hostname Construction

All hostnames are derived in `scripts/lib/config.sh`:
```
# If env_dns_label is empty (prod):
MATRIX_HOST = matrix.example.com
SYNAPSE_ADMIN_HOST = synapse-admin.prod.example.com    # Internal uses "prod" prefix

# If env_dns_label is "dev":
MATRIX_HOST = matrix.dev.example.com
SYNAPSE_ADMIN_HOST = synapse-admin.internal.dev.example.com  # Internal uses "internal" prefix
```

### Terraform Workspaces

Each environment has its own Terraform workspace. **Always verify the workspace before running Terraform**:
```bash
cd phase1 && terraform workspace show    # Should show "dev" or "prod"
cd infra && terraform workspace show
```

---

## 3. Network Architecture

### Traffic Flow

```
External Users:
  Browser → Cloudflare (DDoS/WAF) → NodeBalancer (cloud firewall) → ingress-nginx (infra-ingress) → pod

Tailscale Users (internal services):
  Browser → Tailscale mesh → Node IP:30443 → ingress-nginx-internal (infra-ingress-internal) → pod

Email Inbound:
  Internet MTA → Postfix relay VM:25 → K8s Postfix:25 (via Tailscale mesh) → Stalwart:25

Email Outbound:
  Stalwart:587 → K8s Postfix:587 (DKIM signing) → Postfix relay VM:25 (or SES) → Internet

PostgreSQL:
  K8s pods → PgBouncer (infra-db, with Tailscale sidecar) → PostgreSQL VM (via WireGuard mesh)
```

### Headscale / Tailscale Mesh

- **Headscale**: Self-hosted Tailscale control plane on a dedicated Linode VM
- **CGNAT range**: `100.64.0.0/10` (all mesh nodes get addresses in this range)
- **Members**: Headscale VM, PostgreSQL VM, Postfix relay VM, TURN server, CI server, K8s PgBouncer pods (via Tailscale sidecar)
- **K8s integration**: PgBouncer pods in `infra-db` namespace have a Tailscale sidecar container that joins the mesh
- **Pre-auth keys**: Used for automated node registration (expire after use or time)

**Mesh ↔ K8s connectivity**:
- PgBouncer pod has a Tailscale sidecar that maintains a WireGuard tunnel to the mesh
- PgBouncer connects to the PostgreSQL VM via its Tailscale IP
- K8s pods connect to PgBouncer via `pgbouncer.infra-db.svc.cluster.local`

### Dual Ingress

**Public Ingress** (`infra-ingress`):
- Deployment (2 replicas, anti-affinity)
- Service: LoadBalancer (gets public IP)
- Real IP from Cloudflare `CF-Connecting-IP` header
- TCP proxy: mail ports (Stalwart) via `tcp-services` ConfigMap
- Handles: all user-facing HTTPS traffic + mail ports

**Internal Ingress** (`infra-ingress-internal`):
- DaemonSet (runs on all nodes)
- Service: NodePort (30080 HTTP, 30443 HTTPS)
- Whitelist: Tailscale CGNAT range (100.64.0.0/10)
- IngressClass: `nginx-internal`
- Handles: Grafana, Prometheus, AlertManager, Synapse Admin

### Cloud Firewalls

**NodeBalancer firewall** (infra/main.tf):
- HTTP/S (80, 443): Only from Cloudflare IPs + Tailscale mesh IPs
- Other TCP (1-79, 81-442, 444-65535): Open (mail ports)

**Headscale VM firewall** (modules/headscale/):
- Headscale HTTPS: Open (control plane API)
- WireGuard/DERP: Open
- SSH 22: Admin CIDR only

**Postfix relay VM firewall** (modules/postfix-relay/):
- SMTP 25: Open (inbound mail from internet)
- SSH 22: Admin CIDR only

**PostgreSQL VM firewall**:
- PostgreSQL 5432: Tailscale mesh only (via WireGuard)
- SSH 22: Admin CIDR only

**TURN server firewall** (phase1/main.tf):
- TURN 3478-3479 UDP/TCP: Open
- Media relay 49152-65535 UDP: Open
- SSH 22: Admin CIDR + Tailscale mesh

### Network Policies

Per-tenant namespace policies (`apps/manifests/network-policies/`):
- `allow-intra-namespace` — Pods within same namespace can talk
- `allow-dns-egress` — All pods → kube-dns:53
- `allow-egress-to-infra` — Pods → PostgreSQL:5432, Keycloak:8080/8443, Postfix:25/587
- `allow-internet-egress` — Pods → external HTTPS:443 only
- `allow-kube-api-egress` — Pods → K8s API:6443
- `allow-mail-ingress` — Postfix/Roundcube/ingress → Stalwart mail ports
- `protect-infra-db` — Only whitelisted namespaces → PostgreSQL:5432
- `protect-redis` — Only admin-portal/account-portal app labels → Redis:6379
- `allow-jitsi-media-egress` — JVB → TURN server ports

---

## 4. DNS

### Record Types and Ownership

**Terraform-managed** (modules/dns/ and infra/main.tf) — DO NOT create in scripts:
- Base domain CNAME (`example.com` → `www.example.com`) — NEVER modify
- LB A record (`lb2.prod` for prod, `lb1.<label>` for dev/prod-eu) → cluster ingress IP
- `mail` A record → Postfix relay VM IP
- `turn` A record → TURN server IP
- Matrix federation SRV records

**Script-managed** (create_env via Cloudflare API):
- Tenant CNAME records (matrix, element, docs, files, auth, home, admin, account, webmail, calendar, jitsi, imap, smtp, office)
- Per-tenant MX record
- Per-tenant SPF, DKIM, DMARC TXT records
- Mail autodiscovery SRV records (_imaps._tcp, _submission._tcp)

### CNAME Chain

```
matrix.example.com  →  CNAME  →  lb2.prod.example.com  →  A  →  <ingress-IP>
matrix.dev.example.com  →  CNAME  →  lb1.dev.example.com  →  A  →  <ingress-IP>
```

**Proxied vs DNS-only subdomains**:
- Proxied (Cloudflare): matrix, element, docs, files, auth, home, admin, account, webmail, calendar, jitsi
- DNS-only (bypass Cloudflare): imap, smtp, office

### Internal DNS (Headscale MagicDNS / Tailscale)

Tailscale mesh clients can resolve mesh nodes by Tailscale hostname. For K8s internal services:
- Monitoring services → node internal IP (for NodePort access via Tailscale)
- PostgreSQL VM → reachable via Tailscale IP from PgBouncer sidecar
- Postfix relay VM → reachable via Tailscale IP from K8s Postfix

### TLS Certificates

Per-tenant wildcard cert via cert-manager DNS-01 challenge:
- Prod: `*.example.com` + `*.prod.example.com` + `example.com`
- Dev: `*.dev.example.com` + `*.internal.dev.example.com` + `dev.example.com`
- Secret: `wildcard-tls-<tenant>` — auto-mirrored to all tenant namespaces via Reflector

---

## 5. Email System

### Complete Flow

**Inbound** (receiving mail from internet):
```
1. Sender → DNS MX lookup → mail.example.com (Postfix relay VM IP)
2. Postfix relay VM receives on port 25
3. Transport map routes domain → K8s Postfix (via Tailscale mesh)
4. K8s Postfix (infra-mail:25) performs recipient verification against Stalwart
5. Routes via transport_maps to stalwart.<tenant-ns>.svc.cluster.local:25
6. Stalwart stores: metadata in PostgreSQL, blobs in S3
```

**Outbound** (sending mail to internet):
```
1. User in Roundcube → Stalwart:587 (XOAUTH2 auth via Keycloak)
2. Stalwart relays to K8s Postfix:587 (submission, permit_mynetworks)
3. OpenDKIM sidecar signs with tenant DKIM key (selector: "default")
4. K8s Postfix forwards to Postfix relay VM:25 (relayhost) or SES (optional)
5. Postfix relay VM delivers to internet (consistent source IP for SPF)
```

### Two Postfixes

**Postfix Relay VM** (Ansible-managed, on Tailscale mesh):
- Role: Internet-facing MX, outbound relay
- Why separate: Consistent public IP for SPF, separate from K8s lifecycle
- Config: transport maps + relay_domains per tenant
- TLS: Let's Encrypt cert (Certbot)
- Hostname: `relay.example.com` (avoids "loops back to myself")
- Optional SES outbound relay for improved deliverability

**K8s Postfix** (Terraform-managed, infra-mail namespace):
- Image: `boky/postfix:v5.1.0` + OpenDKIM sidecar `instrumentisto/opendkim:2.10`
- Role: DKIM signing, recipient verification, internal relay
- Port 25: Inbound from Postfix relay VM (reject_unverified_recipient for backscatter prevention)
- Port 587: Submission from internal pods (permit_mynetworks only)
- ConfigMaps: `postfix-config` (main.cf, master.cf), `postfix-routing` (transport, relay_domains), `opendkim-config`

### DKIM Signing

- Selector: Always `default` → `default._domainkey.example.com`
- Key: 2048-bit RSA, per-tenant
- Storage: K8s Secret `dkim-key-<tenant>` in `infra-mail` namespace
- Mount: `/etc/dkim-keys/<tenant>/dkim.private` in Postfix pod
- Tables: OpenDKIM `SigningTable` maps `*@domain` → selector, `KeyTable` maps selector → key file
- Adding a tenant = patch OpenDKIM ConfigMap + add volume + restart Postfix

### Mail Routing Updates

Script: `scripts/configure-mail-routing -e <env>`
- Scans all `tenants/*/config.yaml` files
- Builds transport_maps and relay_domains
- Updates `postfix-routing` ConfigMap
- Called by: deploy_infra, create_env, deploy-stalwart.sh

### Stalwart (Per-Tenant Mail Server)

- Image: `stalwartlabs/stalwart` (check deployed version)
- Namespace: `tn-<tenant>-mail`
- Storage: PostgreSQL (metadata + FTS) + S3 (message blobs)
- Auth: OIDC via Keycloak (port 993) + app passwords (port 994)
- Listeners:
  - Port 25: SMTP inbound from K8s Postfix
  - Port 465: SMTPS (external clients, implicit TLS)
  - Port 587: Submission (external, STARTTLS)
  - Port 588: Submission app passwords (STARTTLS)
  - Port 993: IMAPS OAUTHBEARER (OIDC)
  - Port 994: IMAPS app passwords (PLAIN/LOGIN)
  - Port 4190: ManageSieve (Roundcube)
  - Port 443/8080: JMAP/WebAdmin API

**Port mapping scheme** (multi-tenant unique ports):
```
Tenant 0: SMTPS=46500, Submission=58700, IMAPS=9930, IMAPS-app=9940, Sub-app=5880
Tenant 1: SMTPS=46501, Submission=58701, IMAPS=9931, IMAPS-app=9941, Sub-app=5881
```
Ports mapped via nginx `tcp-services` ConfigMap in `infra-ingress` namespace + LoadBalancer service ports.

**Critical setup step**: After deploying Stalwart, the local email domain MUST be registered via API:
```bash
curl -X POST "http://localhost:8080/api/principal" \
  -u "admin:${PASSWORD}" -H "Content-Type: application/json" \
  -d '{"type": "domain", "name": "example.com"}'
```
Without this, all inbound mail is rejected.

### SPF / DKIM / DMARC

- **SPF** (TXT on email domain): `v=spf1 a:mail.example.com a:mail.dev.example.com include:_spf.mx.cloudflare.net ~all`
- **DKIM** (TXT on `default._domainkey.<domain>`): `v=DKIM1; k=rsa; p=<public_key>`
- **DMARC** (TXT on `_dmarc.<domain>`): `v=DMARC1; p=quarantine; rua=mailto:postmaster@domain; ...`

### Roundcube Webmail

- Namespace: `tn-<tenant>-webmail`
- Auth: OIDC via Keycloak → XOAUTH2 to Stalwart IMAP/SMTP
- ManageSieve: TLS to Stalwart:4190
- Plugins: calendar, managesieve, markasjunk, archive
- Custom mothertree theme with Figtree fonts

### Email Testing

```bash
./scripts/test-email-system -e dev -t example
```
Tests: domain registration, open relay prevention, backscatter prevention, recipient validation, connectivity.

---

## 6. Jitsi

### Components (all in `tn-<tenant>-jitsi` namespace)

1. **Web** (Deployment) — Frontend UI + nginx reverse proxy
2. **Prosody** (StatefulSet, 1 replica) — XMPP server, conference management
3. **JVB** (Deployment, HPA) — Video bridge, media relay via UDP hostPort
4. **Jicofo** (Deployment, 1 replica) — Conference orchestrator
5. **Keycloak Adapter** (Deployment) — OIDC → JWT bridge (`nordeck/jitsi-keycloak-adapter`)
6. **Metrics Exporter** (Deployment) — Prometheus metrics for all components + TURN probes

### JWT Authentication

- JWT App ID: `jitsi-mother-tree`
- Flow: User → "I am the host" → `/oidc/redirect` → Keycloak login → `/oidc/tokenize` → JWT signed with shared secret → join with JWT
- Guests: Join waiting room without JWT, moderators approve
- `enableUserRolesBasedOnToken=true` — Keycloak roles promote to moderator

### TURN/STUN Integration

- TURN server: External Linode instance (phase1 Terraform)
- Shared secret: HMAC-based time-limited credentials
- Prosody pushes TURN credentials to clients via `external_services`
- JVB uses STUN for candidate harvesting
- **Critical**: If TURN fails, users behind NAT cannot call

### JVB Networking

- UDP hostPort per tenant (e.g., 31000, 31002)
- Pod anti-affinity: one JVB per tenant per node (prevents hostPort conflicts)
- Init container discovers node external IP (cloud K8s returns internal IP)
- ICE static mapping: pod IP → node external IP
- TCP harvester disabled (`JVB_TCP_HARVESTER_DISABLED=1`)
- HPA: scales on absolute CPU (2800m threshold), triggers cluster autoscaler

### Element Integration

- Element `jitsi.preferredDomain` set to Jitsi host
- CSP `frame-ancestors` allows embedding from Matrix/Element hosts
- Permissions-Policy: `camera=(self), microphone=(self)`

### Jitsi Calendar (Nextcloud App)

- Custom app in `apps/jitsi_calendar/`
- Adds "Add Jitsi Meeting" button to Nextcloud Calendar
- Generates unique Jitsi room URL as event location

### Known Issues

- Prosody memory: Raised to 512Mi after XML stream corruption at ~342Mi
- Prosody storage: emptyDir (XMPP state rebuilds on restart)
- Prosody/Jicofo: Single replica (SPOF)

### Deploy

```bash
./apps/deploy-jitsi.sh -e dev -t example
```

---

## 7. Nextcloud (Files)

### Zero-Filesystem Architecture

**No PVC** — Nextcloud runs on emptyDir with identity persistence via K8s Secret:

- Secret `nextcloud-identity` stores: instanceid, passwordsalt, secret, version, trusted-domains
- Init container (`seed-identity`) reads secret → populates emptyDir on every pod start
- File data stored in S3 (Linode Objects), not locally
- Enables RollingUpdate (no ReadWriteOnce PVC blocking)

**Auto-migration**: If old PVC exists but no identity secret, script extracts identity from running pod.

### S3 Object Storage

```
Bucket: <env>-<tenant>-files
Region: us-lax-1
Endpoint: <cluster>.linodeobjects.com
usePathStyle: false (DNS-style bucket addressing — critical for Linode)
```

### Database

- Shared PostgreSQL, database per tenant: `nextcloud_<tenant>`
- **Post-install ANALYZE**: Script runs `ANALYZE` to update table statistics after initial install (prevents full sequential scans)
- DB init job: Creates database, sets ownership, revokes PUBLIC connect

### Redis

- Simple single-replica pod in `tn-<tenant>-files` namespace
- Distributed caching + file locking (essential for multi-replica)

### OIDC Integration

- Client: `nextcloud-app` in Keycloak
- Provider configured via `user_oidc` app
- User ID: email address (stable across deployments)
- `allow_multiple_user_backends=0` — forces OIDC-only login

### Apps

Installed via post-deploy job:
- `user_oidc` — OIDC authentication
- `calendar` — Calendar (conditional on `CALENDAR_ENABLED`)
- `richdocuments` — Collabora/Docs integration
- `external` — External site links
- `notify_push` — WebSocket push notifications (port 7867, separate service)
- `integration_google` — Google Drive/Calendar import (optional)
- `files_linkeditor` — Custom linked editing app (bundled)
- `jitsi_calendar` — Jitsi meeting integration (optional)

**App discovery**: Fetches compatible app URLs from Nextcloud App Store API → stores in ConfigMap → init container downloads on every pod start.

### Collabora WOPI Allowlist

```
richdocuments wopi_allowlist = ''  (empty — no IP restriction)
```
The allowlist is intentionally empty. Collabora callbacks traverse Cloudflare in prod
(unpredictable source IPs), so IP-based filtering is not viable. WOPI security relies
on per-request access_tokens (190-bit entropy, file-bound, time-limited).

### Notify_push

- Rust daemon replacing browser polling
- Separate ingress for `/push/` with long timeouts (3600s)
- Sticky sessions via `upstream-hash-by: $remote_addr`

### Calendar Subdomain

- `calendar.<env>.example.com` → redirects to `/apps/calendar`
- Separate ingress with rewrite rules

### Branding

```bash
php occ theming:config primary_color '#A7AE8D'
php occ theming:config name 'Mothertree'
```
Assets from `apps/assets/nextcloud/` (logo, header, favicon SVGs).

### Deploy

```bash
./apps/deploy-nextcloud.sh -e dev -t example
```

---

## 8. Matrix / Synapse / Element

### Synapse (Homeserver)

- Chart: `ananace/matrix-synapse`
- Namespace: `tn-<tenant>-matrix`
- **No PVC**: emptyDir with S3 media storage
- Database: `synapse_<tenant>` — **CRITICAL**: Must use `LC_COLLATE=C, LC_CTYPE=C`
- Redis: Bundled subchart (standalone, no persistence)

### S3 Media Storage

- Module: `synapse-s3-storage-provider==1.6.0` (installed via pip)
- `store_local: true` + `store_remote: true` + `store_synchronous: true`
- Bucket: `<env>-<tenant>-matrix`

### OIDC Authentication

- Client: `matrix-synapse` in Keycloak
- OIDC provider ID: `keycloak`
- Display: "Sign in with MotherTree"
- User mapping: email → localpart, name → display_name
- **Password login disabled**: `password_config.enabled: false`

### Federation

- `server_name`: `example.com` (prod) or `dev.example.com` (dev)
- Well-known endpoints: Only deployed in prod (bare domain ingress for `/.well-known/matrix/`)
- SRV records: `_matrix._tcp` and `_matrix-fed._tcp`

### User Directory

- `search_all_users: true` — Slack-like people search
- `prefer_local_users: true` — Local users rank higher

### TURN Configuration

```yaml
turn_uris:
  - turn:<TURN_IP>:3478?transport=udp
  - turn:<TURN_IP>:3478?transport=tcp
  - turn:<TURN_IP>:3479?transport=udp
  - turn:<TURN_IP>:3479?transport=tcp
turn_shared_secret: <from tenant secrets>
```

### Stable Secrets

`registrationSharedSecret` and `macaroonSecretKey` injected from tenant secrets (prevents random regeneration on helm upgrade).

### Element Web

- Chart: `ananace/element-web`
- Same namespace as Synapse (`tn-<tenant>-matrix`)
- SSO: `sso_redirect_options.immediate: true` (auto-redirect to OIDC)
- `useAuthenticatedMedia: true`
- Jitsi integration: `jitsi.preferredDomain` set
- Custom mothertree themes (light + dark) with Figtree font

**Element branding**: ConfigMap `element-branding` with logo, favicon, font files.

**Static asset caching**: Separate ingress for `/bundles/` with `Cache-Control: public, max-age=31536000, immutable`.

### Deploy

```bash
./apps/deploy-matrix.sh -e dev -t example
./apps/deploy-element.sh -e dev -t example
```

---

## 9. Keycloak & Authentication

### Architecture

- Shared multi-tenant instance in `infra-auth` namespace
- Image: `quay.io/keycloak/keycloak:26.5.1`
- Per-tenant realms with isolated user bases
- Per-tenant auth ingress (e.g., `auth.dev.example.com`)
- Database: Shared PostgreSQL (`keycloak` database)

### Realm Configuration

Per-tenant realm (deployed via `docs/import-keycloak-realm.sh`):
- Registration disabled (admin-invite only)
- Brute force protection enabled
- Sessions: 2h idle, 10h max; Remember Me: 7d idle, 30d max
- Roles: `docs-user` (default), `guest-user`, `tenant-admin`
- Required actions: UPDATE_PASSWORD, VERIFY_EMAIL, webauthn-register-passwordless

### OIDC Clients

| Client | App | Auth Type | Service Account |
|--------|-----|-----------|-----------------|
| `docs-app` | LaSuite Docs | Standard flow | No |
| `matrix-synapse` | Synapse | Standard flow | No |
| `stalwart` | Mail server | Standard + Direct access | No |
| `roundcube` | Webmail | Standard + Direct access | No |
| `admin-portal` | Admin dashboard | Standard flow | Yes |
| `admin-portal-bootstrap` | Admin initial setup | Standard flow | No |
| `account-portal` | User self-service | Standard flow | No |
| `jitsi` | Video conferencing | Public client (no secret) | No |
| `nextcloud-app` | File storage | Standard flow | No |

### Passwordless Authentication (WebAuthn/Passkeys)

**Configuration**:
- RP ID: email domain (e.g., `dev.example.com`)
- Resident key: Required (passkeys stored on authenticator)
- User verification: Required (biometric/PIN)
- Algorithms: ES256, RS256

**User Creation Flow** (Admin Portal invites user):
1. Create user with `tenantEmail` and `recoveryEmail` attributes
2. Swap email to recovery email (so Keycloak sends action token to personal email)
3. Generate HMAC `beginSetupToken` for secure email swap endpoint
4. Send `execute-actions-email` with `webauthn-register-passwordless` action
5. User clicks link → registers passkey on Keycloak WebAuthn form
6. Account Portal `/complete-registration` swaps email back to tenant email
7. User redirected to webmail

**Credential Ordering**: Keycloak 26.5 picks first credential by creation order. `ensurePasskeyFirst()` reorders passkey before password on every login.

**Account Recovery** (lost passkey):
1. User enters tenant email + recovery email on Account Portal `/recover`
2. Validates recovery email matches stored attribute
3. Removes ALL existing WebAuthn credentials
4. Swaps email to recovery, sends new action link (24h lifespan)
5. User registers new passkey, email swapped back

### Guest Users

- Created via Account Portal `/api/guest-register`
- Gets `guest-user` role (not `docs-user`)
- Required actions: VERIFY_EMAIL + webauthn-register-passwordless
- No tenant email, no Stalwart mailbox
- Redirect URI points to shared document

### Theme

- Custom theme in `apps/themes/platform/` (login + email templates)
- Packaged as tar.gz in ConfigMap `keycloak-platform-theme`
- Init container extracts to `/opt/keycloak/themes/`
- Sync: `./apps/scripts/sync-keycloak-theme.sh`

---

## 10. Admin & Account Portals

### Admin Portal (`apps/admin-portal/`)

- **Tech**: Express.js + EJS + Tailwind CSS + Passport.js OIDC
- **Namespace**: `tn-<tenant>-admin`
- **Auth**: Dual OIDC (passkey primary + bootstrap fallback)
- **Session**: Redis-backed, cookie `admin.sid` on shared domain
- **Requires**: `tenant-admin` Keycloak role

**Features**:
- Invite new users (create in Keycloak + send passkey setup email)
- List/manage members and guests
- Set email storage quotas (via Stalwart API)
- Bootstrap admin flow (password → passkey migration)

### Account Portal (`apps/account-portal/`)

- **Tech**: Same stack as Admin Portal
- **Namespace**: `tn-<tenant>-admin` (shared with admin portal)
- **Auth**: OIDC passkey login + registration completion flow
- **Session**: Redis-backed, cookie `account.sid` on shared domain

**Features**:
- Device/app password management for email clients (via Stalwart API)
- Account recovery (lost passkey flow)
- Guest self-registration
- `beginSetup` endpoint with HMAC token validation + rate limiting (20/15min)

### Shared Infrastructure

- Both portals share Redis in `tn-<tenant>-admin` namespace
- Cookie domain shared (`.dev.example.com`) — logout clears both cookies
- Both call `ensurePasskeyFirst()` on every login
- Token refresh middleware: auto-refresh 5 min before expiry

### Deploy

```bash
./apps/deploy-admin-portal.sh -e dev -t example
./apps/deploy-account-portal.sh -e dev -t example
```

---

## 11. Monitoring & Logging

### Stack

```
Prometheus (15s scrape, 14d retention, 8Gi cap) → AlertManager → Email + Matrix webhook
Vector DaemonSet → Loki (7d retention, 10Gi PVC) → Grafana
Blackbox Exporter → HTTP/HTTPS endpoint probes
Email Probe → End-to-end email delivery monitoring
```

### Alert Categories

**Critical alerts** (email + Matrix notification, 1h repeat):
- KeycloakDown, IngressControllerDown, PostfixDown, PostgreSQLDown, AlertManagerDown
- SynapseDown, DocsBackendDown, NextcloudDown, StalwartDown
- JitsiProsodyDown, JitsiJVBDown, JitsiNoBridgesAvailable
- LokiDown, VectorSinkErrors, VectorNoLogsIngested
- EndpointDown, EmailProbeConsecutiveFailures (>=5), EmailProbeNoRecentSuccess (30m)

**Warning alerts** (Matrix only):
- CertificateExpiringSoon (<7d), IngressHighErrorRate (>10% 5xx)
- RoundcubeDown, NotifyPushDown, AdminPortalDown
- JitsiIceFailureRateHigh (>50%), JitsiTurnStunUnreachable
- KubePodNotReady (>5m), KubeContainerOOMKilled, KubeContainerHighRestartRate (>5/1h)

### AlertBot (Matrix Notifications)

- Service user `@alertbot` on Matrix homeserver
- Matrix webhook via `matrix-alertmanager` deployment in `infra-monitoring`
- Rooms: `#alerts` (firing alerts), `#deploys` (deployment notifications)
- Setup: `./apps/scripts/create-alertbot-user.sh` then `./apps/scripts/deploy-alerting.sh`
- Deploy notifications via `scripts/lib/notify.sh` — threaded, nested, includes duration

### Log Pipeline (Vector → Loki)

Vector transforms enrich logs with:
- `tier`: `infra` (infra-* ns), `tenant` (tn-* ns), `system` (other)
- `level`: Extracted from JSON or text pattern matching
- `namespace`, `pod_name`, `container_name`, `node_name`, `app`

**Key LogQL queries**:
```logql
{namespace="tn-example-mail"} | json | line_format "{{.message}}"
{tier="tenant", level="error"} | json | line_format "{{.pod_name}}: {{.message}}"
{pod_name=~"matrix-synapse.*"} |= "federation" | json | line_format "{{.message}}"
topk(10, sum by (pod_name) (count_over_time({job="kubernetes-pods"}[1h])))
```

### Health Scripts

```bash
./scripts/check-health -e dev              # Cluster-wide health
./scripts/check-health -e dev -t example   # Tenant-specific
./scripts/verify-endpoints -e dev -t example  # DNS + HTTP reachability
./scripts/test-email-system -e dev -t example  # Email chain end-to-end
```

---

## 12. Brand Identity

### Color Palette

- **Ash** (`#F3E8D6`): Primary background (warm cream)
- **Coal** (`#141511`): Primary text (near-black)
- **Sage / Ghost Fern** (`#A7AE8D`): Primary accent (muted green-gray)
- **Sage Dark** (`#8A9475`): Hover states
- **Cinder** (`#A64330`): Error/destructive actions
- **Warm Gray** (`#6B6B6B`): Secondary text

### Typography

- **Primary**: Figtree (Google Font, embedded as WOFF2)
- Variants: Regular, Italic, Latin, Latin-ext
- Fallback: system-ui, -apple-system, sans-serif

### Applied Across

| Component | How |
|-----------|-----|
| Keycloak login | Custom `platform` theme (CSS + FTL templates) |
| Keycloak emails | Custom `platform/email` templates (HTML + text) |
| Admin Portal | Tailwind config with brand colors |
| Account Portal | Same Tailwind config |
| Element Web | Custom themes (light + dark) via config |
| Nextcloud | `occ theming:config` — colors, logo, favicon |
| Roundcube | Custom `mothertree` skin |

### Legal / Policy Links

Configurable per environment:
- Privacy Policy URL
- Terms of Use URL
- Acceptable Use Policy URL

Displayed in: Keycloak login footer, email templates, Admin Portal, Account Portal, guest registration.

---

## 13. Common Troubleshooting

### Pod Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| Pod CrashLoopBackOff | `kubectl logs -n <ns> <pod> --previous` | OOM, config error, missing secret |
| Pod Pending | `kubectl describe pod -n <ns> <pod>` | Resource limits, node capacity, PVC binding |
| Pod ImagePullBackOff | `kubectl describe pod` events | Wrong image tag, registry auth |
| Pod stuck Terminating | `kubectl describe pod` | Finalizer, PDB, graceful shutdown timeout |

### Email Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| Inbound mail rejected | Stalwart logs, domain registration | Local domain not registered in Stalwart API |
| DKIM signature missing | OpenDKIM logs, ConfigMap | SigningTable/KeyTable not updated, key not mounted |
| SPF fails | `dig TXT <domain>` | SPF record doesn't include Postfix relay VM IP |
| Mail stuck in queue | `kubectl exec postfix -- mailq` | Stalwart unreachable, transport map wrong |
| Auth fails in Roundcube | Keycloak + Stalwart logs | OIDC token invalid, Stalwart directory config |
| Port unreachable | `tcp-services` ConfigMap | Port mapping not added to nginx + LB service |

### Auth Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| OIDC redirect fails | Keycloak realm config | Client redirect URI mismatch |
| Passkey not offered | Keycloak user credentials | Password created before passkey (ordering) |
| Login loop | Browser cookies, Keycloak sessions | Cookie domain mismatch, session expired |
| Invitation email not sent | Keycloak SMTP config | Postfix unreachable from Keycloak pod |
| Guest can't register | Account portal logs | Email domain validation, role assignment |

### Jitsi Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| No audio/video | TURN probe metrics, JVB logs | TURN unreachable, firewall blocking UDP hostPort |
| "Conference failed" | Prosody logs, BOSH endpoint | Prosody OOM, XMPP session corruption |
| Can't join as moderator | Keycloak adapter logs | JWT signing secret mismatch, adapter down |
| No bridges available | Jicofo metrics | JVB not connected to Prosody MUC |

### Nextcloud Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| Login fails | Nextcloud + Keycloak logs | OIDC config, user_oidc app not installed |
| Files missing after restart | S3 config, identity secret | S3 credentials wrong, identity secret deleted |
| Collabora not loading | richdocuments config, Collabora logs | Check wopi_url, aliasgroups, and that allowlist is empty (not IP-restricted) |
| Slow after fresh install | PostgreSQL stats | Need to run ANALYZE on tables |
| Apps missing after restart | `nextcloud-appstore-urls` ConfigMap | App download URLs stale, re-run deploy |

### Infrastructure Issues

| Symptom | Check | Likely Cause |
|---------|-------|-------------|
| PgBouncer can't reach PG VM | Tailscale sidecar status, PgBouncer logs | Tailscale sidecar disconnected, pre-auth key expired |
| Internal services unreachable | Tailscale status, ingress whitelist | Not connected to mesh, IP not in CGNAT range |
| Cert not renewing | cert-manager logs, DNS challenge | Cloudflare API token expired, DNS propagation |
| Ansible SSH fails | `~/.ssh/known_hosts` | Stale SSH host key for rebuilt VM |

---

## 14. Key Commands Reference

### Cluster Operations
```bash
kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -A
kubectl --kubeconfig=kubeconfig.<env>.yaml get pods -n tn-<tenant>-<service>
kubectl --kubeconfig=kubeconfig.<env>.yaml logs -n <ns> -l app=<app> --tail=50
kubectl --kubeconfig=kubeconfig.<env>.yaml describe pod -n <ns> <pod>
```

### Deployment
```bash
./scripts/manage_infra -e <env> [--plan|--destroy]
./scripts/deploy_infra -e <env>
./scripts/create_env -e <env> -t <tenant>

# Individual components:
./apps/deploy-matrix.sh -e <env> -t <tenant>
./apps/deploy-element.sh -e <env> -t <tenant>
./apps/deploy-nextcloud.sh -e <env> -t <tenant>
./apps/deploy-jitsi.sh -e <env> -t <tenant>
./apps/deploy-stalwart.sh -e <env> -t <tenant>
./apps/deploy-roundcube.sh -e <env> -t <tenant>
./apps/deploy-admin-portal.sh -e <env> -t <tenant>
./apps/deploy-account-portal.sh -e <env> -t <tenant>
./apps/deploy-email-probe.sh -e <env> -t <tenant>
```

### Helmfile
```bash
cd apps
helmfile -e <env> -l name=<release> sync     # Deploy single release
helmfile -e <env> -l tier=system sync         # Deploy all infra
helmfile -e <env> lint                        # Lint all values
helmfile -e <env> diff                        # Show pending changes
```

### Verification
```bash
./scripts/check-health -e <env> [-t <tenant>]
./scripts/verify-endpoints -e <env> -t <tenant>
./scripts/test-email-system -e <env> -t <tenant>
```

### Terraform
```bash
cd phase1 && terraform workspace show && terraform plan
cd infra && terraform workspace show && terraform plan
```

### Mail Debugging
```bash
# Check mail queue
kubectl exec -n infra-mail deploy/postfix -- mailq

# Check transport maps
kubectl exec -n infra-mail deploy/postfix -- cat /etc/postfix/transport

# Check DKIM config
kubectl get configmap opendkim-config -n infra-mail -o yaml | grep -A2 SigningTable

# Check Stalwart domains
kubectl exec -n tn-<tenant>-mail deploy/stalwart -- curl -s -u admin:$PW http://localhost:8080/api/principal?type=domain

# Test SMTP
kubectl exec -n infra-mail deploy/postfix -- sh -c 'echo "test" | mail -s "test" user@example.com'
```

### Nextcloud
```bash
# Run occ commands
kubectl exec -n tn-<tenant>-files deploy/nextcloud -- su -s /bin/bash www-data -c "php occ <command>"

# Common occ commands:
php occ status
php occ app:list
php occ user:list
php occ maintenance:mode --on/--off
php occ notify_push:self-test
php occ db:add-missing-indices
```

### Keycloak
```bash
# Get admin token
curl -X POST "https://auth.<env>.example.com/realms/master/protocol/openid-connect/token" \
  -d "grant_type=client_credentials&client_id=admin-cli&client_secret=<secret>"

# List users in realm
curl -H "Authorization: Bearer $TOKEN" \
  "https://auth.<env>.example.com/admin/realms/<realm>/users"
```

---

## 15. File Reference

| Area | Key Files |
|------|-----------|
| **Scripts** | `scripts/manage_infra`, `scripts/deploy_infra`, `scripts/create_env` |
| **Script libs** | `scripts/lib/common.sh`, `args.sh`, `config.sh`, `infra-config.sh`, `notify.sh` |
| **Helmfile** | `apps/helmfile.yaml.gotmpl` |
| **Helm values** | `apps/values/<component>.yaml` |
| **Env overrides** | `apps/environments/{dev,prod}/<component>.yaml.gotmpl` |
| **Deploy scripts** | `apps/deploy-*.sh` |
| **Manifests** | `apps/manifests/<component>/` |
| **Tenant config** | `tenants/<name>/<env>.config.yaml` |
| **Terraform L1** | `phase1/main.tf`, `modules/lke-cluster/`, `modules/headscale/`, `modules/postgres-server/`, `modules/postfix-relay/`, `modules/dns/` |
| **Terraform L2** | `infra/main.tf`, `infra/templates/` |
| **Ansible** | `ansible/playbook.yml` |
| **Network policies** | `apps/manifests/network-policies/` |
| **Admin Portal** | `apps/admin-portal/server.js`, `api/keycloak.js`, `api/stalwart.js` |
| **Account Portal** | `apps/account-portal/server.js`, `api/keycloak.js` |
| **Keycloak theme** | `apps/themes/platform/` |
| **Keycloak realm** | `docs/keycloak-realm-config.json.tpl` |
| **Monitoring** | `apps/values/prometheus.yaml`, `apps/values/vector.yaml` |
| **Email probe** | `apps/manifests/email-probe/email-probe.yaml.tpl` |
| **Jitsi manifests** | `apps/manifests/jitsi/` |
| **Stalwart config** | `apps/manifests/stalwart/stalwart.yaml.tpl` |
| **Health checks** | `scripts/check-health`, `scripts/verify-endpoints`, `scripts/test-email-system` |
