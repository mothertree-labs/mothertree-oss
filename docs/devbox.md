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
- **minimal** (`init --profile minimal`): the same without Matrix, Docs and S3.

The other apps (Files, Jitsi, mail) are added one at a time; see
[What's not there yet](#whats-not-there-yet).

## Requirements

- **Linux.** Tested on Ubuntu 24.04 arm64; amd64 is expected to work but has
  not been tried yet. `*.localhost` names
  must resolve to loopback; systemd-resolved does that on current distros.
  Ubuntu 18.04 does not. macOS is not supported yet.
- Free memory: about **4.5 GiB** for the standard profile (it measured
  3.7 GiB used in a 6 GiB VM with 4 CPUs), or about **3.5 GiB** and 2 CPUs
  for the minimal one.
- `127.0.0.1:80` and `127.0.0.1:443` free.
- Tools: docker (usable without sudo), [k3d](https://k3d.io) v5.9.0, kubectl,
  helm, helmfile, kustomize, [yq](https://github.com/mikefarah/yq) v4,
  jq, mkcert, openssl, envsubst (gettext), shasum (perl), curl, git, node + npm,
  certutil (`libnss3-tools`).

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
| `init [--profile standard\|minimal] [--regenerate]` | Write `.devbox/` and create + trust the local CA. Re-running keeps the secrets and the last profile |
| `up` | Create or reuse the cluster and PostgreSQL, build missing portal images, run `deploy_infra`, start the S3 gateway and `create_env` |
| `build <component>` | Build `admin-portal` or `account-portal` locally and import it |
| `deploy <app>` | Run `apps/deploy-<app>.sh -e devbox -t devbox` |
| `e2e <spec> [args]` | Run Playwright against the devbox |
| `users <args>` | `scripts/dev-test-users.sh` against the devbox |
| `shell` / `env` | Subshell / exports with `KUBECONFIG` and the config paths |
| `status` | Pods, PostgreSQL, URLs |
| `down` | Delete the cluster and stop PostgreSQL; keeps the data and `.devbox/` |
| `nuke` | Delete the cluster, the PostgreSQL data, `.devbox/` and the CA's trust entries |

## How it works

devbox is a new environment called `devbox` for the normal scripts, not a
separate docker-compose world.

- **`cluster.platform: k3s` + `cluster.edge: local`** in the generated infra
  config. `edge: local` means nothing on the internet points at the cluster.
  The deploy scripts skip whatever needs a public edge, and log why ("edge
  local: …"): Cloudflare DNS and IP checks, Let's Encrypt, the Headscale mesh
  and its CronJobs, and the shared LLM. On every other environment those steps
  are unchanged and a missing token is still fatal.
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
  Upstream images are pulled as usual.
- **S3**: [versitygw](https://github.com/versity/versitygw) in `infra-s3`
  (`apps/manifests/devbox/s3-gateway.yaml.tpl`) serves a directory over the S3
  API with one throwaway key; the buckets are its top-level directories.
  - The tenant config sets `s3.endpoint` to `https://s3.devbox.mothertree.localhost`
    with path-style addressing. Browsers follow Docs' presigned media links to
    that name. Docs' backend reaches the same name through the ingress and
    trusts the local CA (`edge local` mounts it and sets `AWS_CA_BUNDLE`).
  - Synapse only stores media, so it uses `s3.internal_endpoint`, the gateway's
    Service. A devbox-only NetworkPolicy lets the Matrix namespace reach it.
  - On every other environment these settings default to Linode Object Storage
    (`https://<s3.cluster>.linodeobjects.com`, virtual-host style).
- **In-cluster names**: a CoreDNS rewrite (`kube-system/coredns-custom`, key
  `devbox.override`) resolves `*.devbox.mothertree.localhost` to the ingress
  controller inside the cluster. Outside it, those names are loopback.
- **Monitoring** is off (`monitoring.enabled: false`). `deploy_infra` refuses
  that setting anywhere except a dev-class local-edge box.

## What's not there yet

- Files (Nextcloud), Jitsi, mail and webmail. Turning their features on in
  the tenant config is not enough yet. Nextcloud and Stalwart still hardcode
  the Linode S3 endpoint, and mail needs a local relay.
- Email from Matrix and Docs (notifications, Docs invitations): there is no
  mail server yet, so they cannot send email.
- Matrix federation.
- macOS (Docker Desktop's VM memory cap).
- A scheduled CI job that keeps devbox from rotting.

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
