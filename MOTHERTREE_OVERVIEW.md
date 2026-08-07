# Mothertree — Overview, Philosophy & Technical Highlights

> A reference doc for understanding what Mothertree is, why it exists, and how it's
> built. Business/strategy framing is partly **inferred from architectural choices and
> positioning** (the codebase is primarily technical); technical highlights are drawn
> directly from the platform's design.

---

## 1. What Mothertree Is

Mothertree is a **multi-tenant collaboration platform** that gives each organization
("tenant") its own private, branded suite of communication and productivity tools,
running on shared Kubernetes infrastructure. Per tenant it provides:

- **Chat** — Matrix (Synapse) + Element web client
- **Collaborative docs** — Docs (real-time editing, y-provider/CRDT)
- **Files** — Nextcloud
- **Video conferencing** — Jitsi (Prosody, Jicofo, JVB)
- **Email** — Stalwart mail server + Roundcube webmail
- **Self-service & admin** — account portal (users) + admin portal (operators)

Shared, multi-tenant infrastructure underneath: Keycloak (auth/SSO), PostgreSQL,
S3 object storage, Redis/Valkey, NGINX ingress, cert-manager, and a full
Prometheus/Grafana/Vector monitoring stack.

It is, in effect, **a privacy-respecting, self-hostable alternative to the
Google Workspace / Microsoft 365 / Slack + Zoom bundle** — assembled from
best-in-class open-source components rather than a single proprietary vendor.

---

## 2. Business & Market Philosophy

### Core thesis
Organizations should be able to **own their collaboration stack** — their chat,
documents, files, calls, and email — without surrendering their data to Big Tech
SaaS, and without having to assemble and operate a dozen open-source services
themselves. Mothertree packages that operational complexity into a repeatable,
automated platform.

### Positioning
- **Digital sovereignty / data ownership** as the central value proposition.
  Each tenant's data lives in dedicated namespaces, databases, and storage buckets —
  isolation is architectural, not just a UI partition.
- **Open-source all the way down.** The platform is licensed **AGPL-3.0**, and every
  component (Matrix, Nextcloud, Jitsi, Keycloak, Stalwart, Postfix) is open source.
  No proprietary lock-in; tenants/operators can in principle run it themselves.
- **Best-of-breed integration, not reinvention.** Mothertree's value is in the
  *integration, automation, and operations* layer — wiring mature OSS tools together
  with unified SSO, provisioning, DNS, email deliverability, and monitoring — rather
  than building chat/docs/video from scratch.

### Likely target market (inferred from tenant profile)
The platform is multi-tenant and the known tenants skew toward
**mission-driven organizations** — nonprofits, funders/philanthropy networks,
and community/values-aligned groups (e.g. philanthropic funder networks, including EU-hosted tenants).
This suggests a go-to-market focused on:
- Organizations with **data-sovereignty, privacy, or jurisdictional (EU) requirements**
- Groups that want a **branded, all-in-one collaboration home** without IT overhead
- Communities for whom **values alignment** (open source, not surveillance-capitalism)
  is itself a buying criterion

### Operating model & strategy
- **Operator-managed SaaS on open foundations**: the team runs the Kubernetes
  platform and onboards tenants, while the AGPL license keeps the project credibly
  open and forkable.
- **Multi-region / jurisdiction-aware**: separate prod environments per region
  (e.g. a US `prod` and an EU `prod-eu`) let tenants choose where their
  data physically lives — a strategic differentiator for European and
  privacy-sensitive customers.
- **Low marginal cost per tenant**: shared infra + automated, scripted tenant
  provisioning means each new tenant is a config file and a pipeline run, not a
  bespoke deployment — the key to making per-org sovereignty economically viable.
- **Public core, private config**: the platform code is a public repo
  (`mothertree-oss`, AGPL); operator-specific and tenant-specific config (domains,
  secrets, sizing, themes) lives in **private git submodules** under `config/`.
  This balances open-source credibility with operational confidentiality.

---

## 3. Key Technical Highlights

### Architecture at a glance
- **Cloud / orchestration**: Linode Kubernetes Engine (LKE), cluster autoscaler;
  US region (us-lax) for prod, separate EU region for `prod-eu`.
- **Infrastructure as Code**: Terraform (workspaces per env) for cluster, DNS,
  firewall, and VMs; Ansible for VM configuration (Headscale, PostgreSQL, TURN).
- **Deployment**: Helmfile + Helm charts + raw K8s manifests, driven by Go-templated,
  environment-aware config.

### Multi-tenancy & isolation
- **Namespace-per-tenant-per-service**: `tn-<tenant>-matrix`, `tn-<tenant>-docs`,
  `tn-<tenant>-files`, etc., with shared infra in `infra-*` namespaces.
- Each tenant gets its own **Keycloak realm**, **databases**, **S3 buckets**, and
  **Redis** — isolation is enforced at the infrastructure layer.
- New tenants are provisioned from a config template via a single scripted command
  (`create_env -t <tenant>`), making onboarding repeatable and low-touch.

### Three-phase, fully scripted deployment
1. `manage_infra` — Terraform (cluster, DNS, firewall) + Ansible (VMs). Operator-run.
2. `deploy_infra` — shared K8s infra (ingress, certs, PgBouncer, Keycloak, Postfix,
   monitoring). CI-able.
3. `create_env` — per-tenant application stack. CI-able.
   - All sub-scripts are self-contained and independently runnable
     (`deploy-docs.sh`, `deploy-stalwart.sh`, …).

### Identity & SSO
- **Keycloak (OIDC)** with per-tenant realms; passkey support.
- Single sign-on unifies Matrix, Docs, Nextcloud, Jitsi, and webmail under one
  per-tenant identity.

### Email — the hard part, done properly
- **Inbound**: Internet → cluster NodeBalancer:25 → shared K8s Postfix (MX dispatch)
  → per-tenant **Stalwart** mail server.
- **Outbound**: tenant Stalwart → **AWS SES** with SES Easy DKIM signing.
- Full deliverability story: SPF, DKIM, DMARC, plus handling of real-world hazards
  (RBL listings, greylisting/postgrey deferral) — email is treated as a
  first-class, per-tenant capability, not an afterthought.

### Networking & data plane
- **Headscale** (self-hosted Tailscale control plane): all VMs and in-cluster
  PgBouncer pods join a WireGuard mesh (CGNAT range) for secure connectivity to the
  dedicated external **PostgreSQL** VM.
- **PgBouncer** in-cluster connection pooling (with a native Tailscale sidecar to
  avoid zombie connections); careful connection-budget management across tenants.
- Cloudflare for DNS (API-managed A/CNAME/MX/TXT/SRV) and CDN caching;
  TURN/CoTURN for Jitsi media relay.

### CI/CD — test against real deployments
- **Woodpecker CI** on a dedicated Linode VM.
- **PR pipeline**: builds images, leases a dev tenant slot, deploys the PR's code to
  dev, then runs **Playwright E2E tests across 10 shards** against the freshly
  deployed environment — so tests always exercise the actual PR code.
- **Merge-to-main pipeline**: after the gate passes, deploys to prod (all tenants).
- **On-demand dev environment**: dev cluster can be reaped and rebuilt to save cost,
  with automated bring-up.
- **Secrets**: Ansible-Vault-encrypted archives committed in the private config
  submodule, decrypted at build time and cleaned up on exit; private config
  submodules pulled via fine-grained PAT.

### Operational engineering maturity
- **Conditional restart system** (`mt_apply` / `mt_restart_if_changed`): deploys only
  restart pods when their config actually changed — avoids disrupting active Jitsi
  calls, doc editing sessions, and logins on every deploy.
- **Fail-fast discipline**: scripts must fail loudly on missing secrets/inputs;
  never silently skip security-critical paths (locking, auth, encryption).
- **Release versioning**: semver `VERSION` file + deploy-time release string
  (`<version>-<hash>[-M]`) exposed via a `/version` endpoint on the portals.
- **Monitoring**: Prometheus + Grafana + AlertManager + Vector log pipeline,
  with operator access to internal dashboards over the Tailscale mesh.

### Compliance & OSS hygiene
- The public repo is scanned before every commit/PR for leaked credentials, real
  tenant domains, or private-registry references (automated compliance + security
  review agents) — reflecting the public-core / private-config split.

---

## 4. One-paragraph summary

**Mothertree is an AGPL-licensed, multi-tenant collaboration platform that gives
mission-driven organizations their own private, branded suite of chat, docs, files,
video, and email — built by integrating best-in-class open-source tools (Matrix,
Nextcloud, Jitsi, Keycloak, Stalwart) on autoscaling Kubernetes. Its strategic bet is
that data sovereignty plus low-touch, automated per-tenant provisioning can make
"own your own collaboration stack" economically viable — turning what would be a
dozen hard-to-operate services into a single, monitored, multi-region, repeatably
deployed platform.**
