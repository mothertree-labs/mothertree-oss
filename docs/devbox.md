# devbox: Mothertree on your own machine

`scripts/devbox` runs Mothertree on a local single-node Kubernetes cluster
(k3d) using **the same deploy scripts and manifests** as the real
environments. You can build one image, deploy one app and run one Playwright
spec in a few minutes, without waiting for the CI pipeline.

It works from a plain `git clone` of this repository. You don't need config
submodules, a vault password or any cloud account. Every secret is generated
on your machine and is throwaway.

`init` picks a profile:

- **standard** (the default):
  - Keycloak with one tenant realm, and the admin and account portals with a real browser OIDC login;
  - **Matrix** (Synapse + Element) and **Docs**, storing their media in an in-cluster S3 gateway;
  - ingress-nginx, cert-manager, PgBouncer and a PostgreSQL container.
- **full** (`init --profile full`): standard plus **Files** (Nextcloud),
  **mail** (a Stalwart server for the tenant), **webmail** (Roundcube,
  built locally like the portals), **Jitsi**, the Nextcloud **calendar**
  with its calendar automation (invitations by email), and the **magic-link**
  login. Mail is delivered between devbox users, and mail to any other address
  lands in **Mailpit**; nothing leaves the machine.
- **everything** (`init --profile everything [--llm-model M]`): full plus
  **Office** (Collabora, opened from Files) and the **LLM chat** (Open WebUI
  with an Ollama backend and SearXNG web search). The model defaults to
  `llama3.2:1b`; pick a smaller one such as `qwen2.5:0.5b` with `--llm-model`
  (any Ollama model name; remembered in `.devbox/llm-model`). Unlike the real
  environments there is no S3 model cache: Ollama pulls the model from
  ollama.com whenever its pod starts.
- **minimal** (`init --profile minimal`): the same as standard without Matrix, Docs and S3.

## Requirements

- **Linux.** Tested on Ubuntu 24.04, amd64 and arm64. `*.localhost` names
  must resolve to loopback; systemd-resolved does that on current distros.
  Ubuntu 18.04 does not. macOS is not supported yet.
- Free memory: about **4.5 GiB** for the standard profile (it measured
  3.7 GiB used in a 6 GiB VM with 4 CPUs), about **3.5 GiB** and 2 CPUs
  for the minimal one, about **8.5 GiB** and 4–6 CPUs for the full one
  (it measured 7 GiB used on a 16 GiB, 6-CPU machine), and about
  **11.5 GiB** for everything with a small model (more for a bigger model).
  A first full `up` took 24 minutes there with empty image caches.
- `127.0.0.1:80` and `127.0.0.1:443` free.
- Disk: about **30 GiB free** for docker with the full profile (images, the
  image caches and the Roundcube and portal build cache); less for the smaller
  profiles.
- Tools: docker (usable without sudo), [k3d](https://k3d.io) v5.9.0, kubectl,
  helm, helmfile, kustomize, [yq](https://github.com/mikefarah/yq) v4,
  jq, mkcert, openssl, envsubst (gettext), shasum (perl), curl, git, node + npm,
  certutil (`libnss3-tools`).
- `fs.inotify.max_user_instances` of at least 512 if other k3s clusters or
  IDEs run next to it (the common default of 128 can stop k3s from starting).

`scripts/devbox doctor` checks all of these.

## Quick start

```bash
scripts/devbox doctor   # prerequisites, ports, memory, name resolution
scripts/devbox init     # writes .devbox/ and creates + trusts a local CA
scripts/devbox up       # cluster, PostgreSQL, portal images, deploy_infra, create_env
```

The first `up` takes about 10–15 minutes. Most of that is image pulls and
Keycloak's first boot. When it finishes:

- Admin portal: <https://admin.devbox.mothertree.localhost>
- Account portal: <https://account.devbox.mothertree.localhost>
- Element (Matrix): <https://matrix.devbox.mothertree.localhost>
- Docs: <https://docs.devbox.mothertree.localhost>
- Files (full profile): <https://files.devbox.mothertree.localhost>
- Webmail (full profile): <https://webmail.devbox.mothertree.localhost>
- Jitsi (full profile): <https://jitsi.devbox.mothertree.localhost>
- Mailpit, outbound mail (full profile): <https://mailpit.devbox.mothertree.localhost>
  (user `devbox`, password `cat .devbox/mailpit-ui-password`)
- Keycloak: <https://auth.devbox.mothertree.localhost/admin/> (user `admin`,
  password `yq .keycloak.admin_password .devbox/tenants/devbox/devbox.secrets.yaml`)

Create a user to log in with:

```bash
scripts/devbox users create alice --password 'a-long-password' --admin
```

## The inner loop

```bash
# change apps/admin-portal/..., then:
scripts/devbox build admin-portal     # docker build + k3d image import (unique tag)
scripts/devbox deploy admin-portal    # apps/deploy-admin-portal.sh -e devbox -t devbox
scripts/devbox e2e tests/admin-portal/login.spec.ts
```

Before the first `e2e`, install Playwright's browser once:
`cd e2e && npm ci && npx playwright install --with-deps chromium`
(`--with-deps` installs the system libraries with sudo). `scripts/devbox e2e
tests/` runs the whole suite. Specs for apps the profile does not deploy
(Office, LLM, and on the smaller profiles Files, mail, calendar …) and the
ones that need mail to leave for the internet skip themselves: `e2e` passes
the tenant's switched-off features in `E2E_DISABLED_FEATURES`.

Each `build` gets a unique tag, so the following `deploy` always rolls the
pod. The tag is recorded in `.devbox/images.env`.

For anything else, `scripts/devbox shell` opens a subshell where `kubectl`,
`helmfile` and every `apps/deploy-*.sh` / `scripts/*` command already point at
the devbox, so you can run things like `kubectl get pods -A` or
`./apps/deploy-admin-portal.sh -e devbox -t devbox` directly.

## Commands

| Command | What it does |
|---|---|
| `doctor` | Check tools, docker access, `*.localhost` resolution, ports, memory, browser CA trust |
| `init [--profile minimal\|standard\|full\|everything] [--llm-model M] [--regenerate]` | Write `.devbox/` and create + trust the local CA. Re-running keeps the secrets, the last profile and the LLM model |
| `up` | Create or reuse the cluster and PostgreSQL, build missing portal images, run `deploy_infra`, start the S3 gateway and `create_env` |
| `build <component>` | Build `admin-portal`, `account-portal` or `roundcube` locally and import it |
| `deploy <app>` | Run `apps/deploy-<app>.sh -e devbox -t devbox` |
| `e2e <spec> [args]` | Run Playwright against the devbox (with mail on, it port-forwards Stalwart's IMAPS and submission ports for the mail specs); specs for switched-off features skip |
| `users <args>` | `scripts/dev-test-users.sh` against the devbox |
| `shell` / `env` | Subshell / exports with `KUBECONFIG` and the config paths |
| `status` | Pods, PostgreSQL, URLs |
| `cache [status\|clear]` | Sizes of the pull-through image caches; `clear` deletes them |
| `down` | Delete the cluster and stop PostgreSQL; keeps the data, `.devbox/` and the image caches |
| `nuke` | Delete the cluster, the PostgreSQL data, `.devbox/` and the CA's trust entries; keeps the image caches |

## How it works

devbox is a new environment called `devbox` for the normal scripts, not a
separate docker-compose world.

- **`cluster.platform: k3s` + `cluster.edge: local`** in the generated infra
  config. `edge: local` means nothing on the internet points at the cluster.
  The deploy scripts skip whatever needs a public edge, and log why ("edge
  local: …"): Cloudflare DNS and IP checks, Let's Encrypt, the Headscale mesh
  and its CronJobs, and the shared LLM unless `llm.enabled` (everything
  profile; then without the S3 model cache). On every other environment those
  steps are unchanged and a missing token is still fatal.
- **Local CA inside pods**: apps that call another devbox name over HTTPS
  server side get the CA from ConfigMap `mt-local-ca`
  (`scripts/lib/local-ca.sh`): Docs (S3 and SMTP), Open WebUI (Keycloak) and
  Collabora (WOPI callbacks to Files). Nextcloud reaches Keycloak and
  Collabora at their in-cluster URLs instead, because PHP's libcurl resolves
  every `*.localhost` name to loopback on its own.
- **Config**: `scripts/devbox` points the deploy scripts at the gitignored
  `.devbox/` directory through `MT_TENANTS_DIR`, `MT_INFRA_CONFIG_DIR`,
  `MT_PROJECT_CONF` and `KUBECONFIG` (see `scripts/lib/paths.sh`). One tenant,
  `devbox`, is both the infra tenant and the app tenant. Its features live in
  `.devbox/tenants/devbox/devbox.config.yaml`.
- **Names**: `*.devbox.mothertree.localhost`. Browsers and systemd-resolved
  resolve `*.localhost` to loopback by themselves (RFC 6761).
- **TLS**: `init` creates a CA and has mkcert add it to the system and NSS
  trust stores (this asks for sudo once). The CA carries a critical
  `nameConstraints` extension, so it can only vouch for `*.localhost` names,
  loopback addresses and `@localhost` email, even though its key also lives in
  a cluster Secret for cert-manager. cert-manager's issuers keep their usual names
  (`letsencrypt-prod`, `letsencrypt-dns01-<tenant>`, …) but sign with that CA,
  so every Certificate and ingress deploys unchanged.
- **Ingress**: k3d publishes the node's 80/443 on `127.0.0.1` only, and
  ingress-nginx runs with PROXY protocol off
  (`apps/environments/devbox/ingress-nginx.yaml.gotmpl`).
- **PostgreSQL**: a `postgres` container on the k3d network at `172.29.0.20`.
  PgBouncer runs as everywhere else, but with `pgbouncer.mesh: false` (no
  Tailscale sidecar), so apps keep using the same `PG_HOST`. The bootstrap SQL
  is shared with devhome (`scripts/lib/pg-bootstrap-sql.sh`).
- **Images**: the portals are always built locally (`CONTAINER_REGISTRY=localhost`).
  Upstream images come through **pull-through caches**: one `registry`
  container per upstream (Docker Hub, ghcr.io, quay.io, registry.k8s.io) on
  their own docker network (`devbox-cache`) with no published ports, and k3s
  mirror settings (`.devbox/registries.yaml`) pointing at them. Their volumes
  outlive `down` and `nuke` and never expire content, so a recreated cluster
  pulls from disk; `scripts/devbox cache clear` deletes them. k3s falls back
  to the upstream when a cache does not answer, which covers the few images a
  new node pulls before `up` attaches it to the cache network. A cluster
  created before the caches existed keeps pulling from the internet until it
  is recreated (`up` says so).
- **CA trust without root** (`DEVBOX_TRUST=process`, used by the CI drift
  check): `init` installs nothing and writes `.devbox/ca/bundle.pem` (the
  system CAs plus the devbox CA), and every devbox command points curl, Go,
  Python and Node at it. Browsers on that machine do not trust the devbox.
- **S3**: [versitygw](https://github.com/versity/versitygw) in `infra-s3`
  (`apps/manifests/devbox/s3-gateway.yaml.tpl`) serves a directory over the S3
  API with one throwaway key; the buckets are its top-level directories.
  - The tenant config sets `s3.endpoint` to `https://s3.devbox.mothertree.localhost`
    with path-style addressing. Browsers follow Docs' presigned media links to
    that name. Docs' backend reaches the same name through the ingress and
    trusts the local CA (`edge local` mounts it and sets `AWS_CA_BUNDLE`).
  - Synapse and Nextcloud only store objects (Nextcloud proxies downloads), so
    they use `s3.internal_endpoint`, the gateway's Service. A devbox-only
    NetworkPolicy lets the Matrix and Files namespaces reach it.
  - On every other environment these settings default to Linode Object Storage
    (`https://<s3.cluster>.linodeobjects.com`, virtual-host style).
- **Keycloak from pods**: libcurl (and so PHP, e.g. Nextcloud) resolves any
  `*.localhost` name to loopback without asking DNS. The devbox Keycloak
  (`apps/environments/devbox/keycloak.yaml.gotmpl`) runs with
  `--hostname-backchannel-dynamic`, and on `edge: local` Nextcloud's
  `user_oidc` fetches discovery from Keycloak's in-cluster Service, which then
  advertises in-cluster token, userinfo and JWKS endpoints. The issuer and the
  browser endpoints stay `https://auth.devbox.mothertree.localhost`.
- **Keycloak's truststore**: realm mail (invitations, password resets) goes
  to the tenant's Stalwart over STARTTLS with a local-CA certificate, so the
  devbox Keycloak values mount the CA (`KC_TRUSTSTORE_PATHS`).
- **Mail**: Stalwart only. Postfix (inbound internet MX) and the load-balancer
  TCP ports for IMAP/SMTP are skipped on `edge: local` ("edge local: …" in the
  logs). Mail for other domains goes to **Mailpit** in `infra-mailpit`
  (`apps/manifests/devbox/mailpit.yaml.tpl`): the generated infra config sets
  `mail.smtp_relay` to its Service name, which `mt_load_infra_config` accepts
  only on `edge: local` (everywhere else the relay must be a tailnet IP), and
  `deploy-stalwart.sh` opens Stalwart's egress to that namespace only. The web
  UI has a generated login because the inbox holds reset and invitation links.
  The SMTP smoke test after provisioning trusts the local CA.
- **Jitsi**: JVB's media port (31000/udp) is published on `127.0.0.1` when the
  cluster is created (k3d cannot add ports later; `up` warns if an older
  cluster lacks it — `down` then `up` recreates it and keeps PostgreSQL and
  `.devbox/`). JVB advertises 127.0.0.1 and runs without STUN (there is no
  TURN server); the intent is calls between browsers on the same machine
  (not yet tested). Its
  ServiceMonitor is skipped when monitoring is off.
- **In-cluster names**: a CoreDNS rewrite (`kube-system/coredns-custom`, key
  `devbox.override`) resolves `*.devbox.mothertree.localhost` to the ingress
  controller inside the cluster. Outside it, those names are loopback.
- **Monitoring** is off (`monitoring.enabled: false`). `deploy_infra` refuses
  that setting anywhere except a dev-class local-edge box.

## What's not there yet

- Jitsi sign-in on **arm64** hosts: the Keycloak adapter image
  (`nordeck/jitsi-keycloak-adapter`) is published for amd64 only, so on arm64
  its pod cannot pull and joining a room stops at the SSO step. Jitsi itself
  deploys and the app loads. A two-browser call has not been tested yet.
- The mail e2e specs that need real outside mail: `email-roundtrip` (external
  echo group) and `dkim-signature-validation`. They skip.
- Nextcloud's notify_push on arm64 (its image is amd64-only; it is skipped
  there and clients poll).
- An S3 model cache for the LLM: the everything profile's Ollama downloads
  its model again on every new pod.
- The S3 gateway's data lives in the k3d node, so `down` loses uploaded media
  (the PostgreSQL data survives).
- Email in the standard profile: it has no mail server, so Matrix and Docs
  cannot send notifications or invitations (use the full profile).
- Matrix federation.
- macOS (Docker Desktop's VM memory cap).

## Drift check

A scheduled CI job on devhome (`.woodpecker/devbox-drift.yaml`) builds the
minimal profile from a plain checkout every night and runs the admin-portal
login spec against it (see `ci/RUNBOOK.md`). A red cron pipeline on `main`
means a merged change broke the devbox.

## Troubleshooting

- **`doctor` says `*.localhost` does not resolve**: add the hosts you need
  to `/etc/hosts` (`127.0.0.1 admin.devbox.mothertree.localhost` and so on),
  or use a distro with systemd-resolved.
- **Certificate warnings in the browser**: the CA is not in your browser's
  store. Run `scripts/devbox init` again (it re-runs `mkcert -install` with the
  system and NSS stores) and restart the browser. Snap-packaged Firefox keeps
  its profile under `~/snap/firefox/common/.mozilla`; if mkcert misses it,
  enable `security.enterprise_roots.enabled` in `about:config`.
- **A code change doesn't show up**: deploy after `build`. The new tag is
  only picked up by the next `deploy`. `scripts/devbox env | grep IMAGE` shows
  the current refs.
- **After pulling a newer devbox**: run `scripts/devbox init` again. It keeps
  your secrets and profile, regenerates the configs with the new defaults, and
  adds any newly needed secrets (such as the S3 key). Then run `scripts/devbox up`.
- **Start over**: `scripts/devbox nuke && scripts/devbox init && scripts/devbox up`.
  `init --regenerate` refuses to run while a cluster or database exists: new
  secrets against an old Keycloak database would break every OIDC client.
