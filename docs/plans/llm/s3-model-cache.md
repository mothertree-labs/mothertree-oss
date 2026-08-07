# S3 Model Cache for Ollama

Replace the Ollama model-weights PVC (prod) / internet-pull-on-start (dev) with an
`emptyDir` + restore-from-S3 (Linode Object Storage) pattern so the Ollama
deployment becomes stateless. Mirrors [issue #450](https://github.com/mothertree-labs/mothertree-oss/issues/450).

## Problem

- Prod currently stores weights in an RWO `linode-block-storage-retain` PVC,
  created inline in `apps/deploy-llm.sh` (a 10 Gi claim). RWO forces
  `strategy: Recreate` (downtime per deploy) and rules out >1 replica.
- Every pod start runs `ollama pull ${LLM_MODEL}` (`apps/manifests/llm/ollama.yaml.tpl:33`)
  over the internet. Cold pull is **15–20 min** over constrained cluster egress,
  painful in dev where pods restart often.
- `llama3.2:1b` ≈ 800 MB, `gemma2:2b` ≈ 1.6 GB, `mistral:7b` ≈ 4.2 GB.
- The PVC exists only as a cache; the source of truth is Ollama's registry. Swap
  the cache backend to `emptyDir` and restore from our own in-region bucket instead.

## Proposed Solution

```
                                        ┌──────────────────┐
                                        │  Linode Objects  │
                                        │  (us-lax-1)      │
                                        │  bucket:         │
                                        │  mothertree-models│
                                        │  /ollama/         │
                                        └────────┬─────────┘
                                                 │ aws s3 sync
                                        ┌────────▼─────────┐
                                        │  Ollama Pod       │
                                        │  ┌──────────────┐ │
                                        │  │ initContainer│ │
                                        │  │ restore-models│ │
                                        │  └──────┬───────┘ │
                                        │         ▼         │
                                        │  ┌──────────────┐ │
                                        │  │ emptyDir     │ │
                                        │  │ /root/.ollama│ │
                                        │  └──────────────┘ │
                                        │  ┌──────────────┐ │
                                        │  │ ollama serve │ │
                                        │  └──────────────┘ │
                                        └──────────────────┘
```

Seed path (runs once per bucket lifetime, survives dev cluster teardown because
the bucket is external to the cluster):

```
ollama.com ──ollama pull──▶ emptyDir ──aws s3 sync──▶ bucket (seed Job)
```

## Proposed Design

### 1. Serving Deployment — `apps/manifests/llm/ollama.yaml.tpl`

- **Remove** the PVC volume; replace with `emptyDir: {}` mounted at
  `/root/.ollama`. Keep it a **default disk-backed** emptyDir — do **not** set
  `medium: Memory` (the multi-GB model would count against pod memory).
- Add an initContainer `restore-models` (pinned aws-cli image) that restores
  weights before Ollama starts:
  ```yaml
  initContainers:
    - name: restore-models
      image: amazon/aws-cli:2.22.35
      command: ["sh", "-c", "aws s3 sync --no-progress s3://${LLM_S3_BUCKET}/${LLM_S3_PREFIX}/ /root/.ollama/"]
      envFrom:
        - secretRef:
            name: ollama-s3
      env:
        - name: AWS_ENDPOINT_URL
          value: "https://${LLM_S3_ENDPOINT}"
        - name: AWS_REGION
          value: "${LLM_S3_REGION}"
      volumeMounts:
        - name: ollama-models
          mountPath: /root/.ollama
  ```
  Same `emptyDir` shared with the `ollama` container. Fast in-region copy when the
  bucket is populated; harmless no-op when it isn't.
- **Simplify the main container** to just `ollama serve` — drop the `ollama pull`
  from the command (line 33). Keep `OLLAMA_HOST`/`OLLAMA_KEEP_ALIVE`/probes.
- With the volume lock gone, flip `strategy` from `Recreate` to
  `RollingUpdate` with `maxUnavailable: 0` (see Open Decisions 4).

### 2. Remove the PVC

- Delete the inline PVC creation in `apps/deploy-llm.sh` (the
  `OLLAMA_STORAGE_VALUE` prod/dev branching, lines ~56–80) and the
  `${OLLAMA_STORAGE_VALUE}` placeholder in the manifest — the volume is now a
  hardcoded `emptyDir: {}`. Drop the `.llm.storage_size` PVC usage.
- `kubectl get pvc,pv -n infra-llm` should be empty after rollout.

### 3. Seed Job — `apps/manifests/llm/ollama-model-seed-job.yaml` (new)

One-shot Job that populates the bucket from `ollama.com` the first time (and
re-seeds if the bucket is ever wiped):

- **initContainer `pull`** (ollama image): `ollama serve &` → wait for
  `/api/tags` ready → `ollama pull "$LLM_MODEL"` into a shared `emptyDir` at
  `/root/.ollama`. (Init containers finish before the main container starts, so
  ordering is guaranteed.)
- **main container `upload`** (aws-cli): `aws s3 sync /root/.ollama s3://${LLM_S3_BUCKET}/${LLM_S3_PREFIX}`.
  Exits 0 → Job complete.
- `restartPolicy: OnFailure`, `backoffLimit` bounded, both containers `envFrom`
  the `ollama-s3` Secret, `LLM_MODEL` templated from infra config.

### 4. S3 credentials + config wiring

- **Infra config** (`config/platform/infra/<env>.config.yaml`, private) — add
  non-secret keys alongside the existing `llm.model` block:
  ```yaml
  llm:
    model: ...        # existing
    s3_bucket: mothertree-models
    s3_endpoint: us-lax-1.linodeobjects.com
    s3_region: us-lax-1
    s3_prefix: ollama
  ```
- **Infra secrets** (`config/platform/infra/<env>.secrets.yaml`, private) — add:
  ```yaml
  llm:
    s3_key: <access-key>
    s3_secret: <secret-key>
  ```
- **`scripts/lib/infra-config.sh`** — load non-secret values in the config loader
  next to the `pgbackrest.s3_*` block (~line 106) as `LLM_S3_BUCKET` /
  `LLM_S3_ENDPOINT` / `LLM_S3_REGION` / `LLM_S3_PREFIX`; load the secrets in the
  secrets loader next to `pgbackrest.s3_key/s3_secret` (~line 412) as `LLM_S3_KEY`
  / `LLM_S3_SECRET`. Follow the fail-fast convention (`CLAUDE.md`): the seed Job
  and restore path are expected to run, so required inputs are validated — no
  silent skip.
- **`apps/deploy-llm.sh`** — create a K8s Secret `ollama-s3` in `infra-llm` from
  those env vars, wrapped in **`mt_apply`** so a credential change is tracked and
  triggers a rollout (conditional-restart system per `CLAUDE.md`). Referenced via
  `envFrom` in the restore initContainer (§1) and the seed Job (§3).
- Note: existing per-tenant S3 keys (`s3_docs`/`s3_matrix`/…) are **tenant-scoped**
  to tenant buckets and not usable for this shared-infra service — a dedicated key
  is required (see Bucket & IAM).

### 5. `apps/deploy-llm.sh` flow changes

- Load `LLM_S3_*` from infra config/secrets; create the `ollama-s3` Secret (`mt_apply`).
- **Gate + apply the seed Job idempotently and non-blocking**: check whether the
  model manifest already exists in the bucket (e.g.
  `aws s3 ls s3://<bucket>/<prefix>/manifests/.../<model>`); only `kubectl apply`
  the seed Job if absent. Do **not** `kubectl wait` on it — the 15–20 min pull
  must not block `deploy_infra` (and must not blow the CI tenant-lease TTL).
- Remove the in-pod pull warm-up (the manifest command, §1).
- Keep the existing post-deploy verification (`/api/tags` model listing).

## Bucket & IAM

Per-env bucket in the same Linode Object Storage cluster used elsewhere
(us-lax-1 for dev/prod, nl-ams-1 for prod-eu). No public access — S3 keys only.

- **Read key** for the pod restore initContainer (least privilege, read-only).
- **Write key** for the seed Job `upload` container (and any manual re-seed).

Provisioning is Terraform-managed for prod/prod-eu (`phase1/main.tf` —
`linode_object_storage_bucket.llm_models` + `linode_object_storage_key.llm_models`,
created by `manage_infra -e <env> --phase1`), matching the `phase1-dev` `dev_state`
precedent. The dev bucket was created out-of-band (Phase 0) and the dev workspace
skips the resources (`count = var.env == "dev" ? 0 : 1`) to avoid colliding with
the manually-created `mothertree-models` bucket in us-lax-1. After apply, read the
scoped secret key with `terraform output -raw llm_models_secret_key` and store it
in the infra tenant secrets as `llm.s3_secret`.

## Resolved Decisions

1. **Dedicated bucket, not a prefix in the pgbackrest bucket.** Model blobs are
   large with a different lifecycle than DB backups; a dedicated bucket allows a
   least-privilege credential scoped to just the weights.
2. **Dedicated scoped key, not the pgbackrest credential.** One key per env,
   scoped `read_write` to its bucket only (serves both the restore initContainer
   and the seed Job).
3. **Terraform provisioning in `phase1/` for prod/prod-eu** (managed by
   `manage_infra --phase1`); **dev provisioned out-of-band** (Phase 0, skipped by
   Terraform). Bucket labels: `mothertree-models` (dev, manual), `mothertree-models-prod`,
   `mothertree-models-prod-eu`.
4. **`RollingUpdate` now** (`maxUnavailable: 0`) — safe once emptyDir removes the
   volume lock.
5. **Auto-seed Job** so on-demand-dev stays hands-off.

## Edge Cases

- **First-ever deploy, empty bucket:** restore initContainer is a no-op → Ollama
  starts modelless → lazy-pulls on first request, while the seed Job populates the
  bucket in the background (~once). Next pod restart restores in seconds.
- **`aws s3 sync` safety:** Ollama blobs are content-addressed (`sha256-…`), so
  sync is idempotent. Omit `--delete` to be conservative.
- **Image pinning (per `CLAUDE.md`):** pin the aws-cli image to a real tag and
  confirm against the registry before merge. (`ollama/ollama:latest` and
  `open-webui:main` remain mutable — pinning those is a separate follow-up.)
- **DNS unchanged** — `llm.<domain>` already managed by `manage-dns.sh`.

## Migration

1. Wire `llm.s3_*` config/secrets + `infra-config.sh` loading.
2. `deploy_infra -e <env>` — seed Job populates the bucket once (non-blocking);
   Ollama redeploys with `emptyDir` + restore initContainer.
3. No tenant disruption — models are identical, just sourced differently.
4. Post-deploy: `kubectl get pvc,pv -n infra-llm` is empty; `kubectl rollout
   restart deploy/ollama -n infra-llm` restores weights in seconds, model listed
   in `/api/tags`.

## Testing / Acceptance

- Deploy to dev; confirm the bucket gets seeded once (seed Job runs, model objects
  appear under `<prefix>/blobs/` + `<prefix>/manifests/`).
- `kubectl rollout restart deploy/ollama -n infra-llm` → new pod ready in
  ~seconds–low-minutes (S3 restore), **not** a 15–20 min cold pull, with the model
  present (`/api/tags` lists it).
- No PVC/PV remains in `infra-llm` (`kubectl get pvc,pv -n infra-llm` is empty).
- Deployment can run `RollingUpdate` / >1 replica without volume-attach errors.
- `deploy_infra -e dev` does not block on the model pull (completes promptly even
  on a cold/empty-bucket cluster).

## Alternatives Considered

| Approach | Pros | Cons |
|----------|------|------|
| **PVC** (current prod) | No S3 dependency, zero-copy | RWO forces `Recreate`, blocks RollingUpdate/multi-replica, stuck volumes |
| **Init container + S3** (this plan) | Stateless, fast in-region restore | Extra bucket to manage, extra seed Job |
| **FUSE-mount bucket** (s3fs/goofys) | No local copy | Ollama does concurrent content-addressed writes; FUSE-S3 is slow, lacks locking, risks corruption — explicitly not this |
| **Sidecar + rsync** | No S3 dependency | Needs a persistent model-server pod, more complex |
| **emptyDir + internet pull** (current dev) | Simple, zero config | 15–20 min slow restarts, internet dependency, wasted bandwidth |

## Execution Plan (Phases)

Decisions locked: dedicated bucket + key, Terraform provisioning for prod/prod-eu
(dev out-of-band), `RollingUpdate` now, target envs dev + prod + prod-eu.

### Phase 0 — Provision (dev) ✅ DONE
- [x] Create bucket `mothertree-models` in `us-lax-1` (private ACL,
      `mothertree-models.us-lax-1.linodeobjects.com`) via Linode API
- [x] Create dedicated limited key `mothertree-llm-dev` (id 4840464), scoped
      `read_write` to the `mothertree-models` bucket only
- [x] Persist key in `config/tenants/mothertree/dev.secrets.yaml` under
      `llm.s3_key` / `llm.s3_secret` (gitignored source for `build-deploy-vaults.sh`)
- [x] Verify: put/get/delete round-trip with the new key against the bucket

> Note: `dev.secrets.yaml` is gitignored and assembled into the deploy vault by
> `scripts/build-deploy-vaults.sh` — rebuild the dev vault before CI can read
> `llm.s3_*`. The read-write key serves both restore and seed (single key).

### Phase 0b — Terraform provisioning (prod/prod-eu) ✅ DONE (code; apply pending)
- [x] Add `linode_object_storage_bucket.llm_models` +
      `linode_object_storage_key.llm_models` to `phase1/main.tf`
      (`count = var.env == "dev" ? 0 : 1`), per-env labels
      `mothertree-models-<env>`, scoped `read_write` key, region defaults to
      `linode_region` (us-lax prod / nl-ams prod-eu)
- [x] Add `llm_models_bucket_label` / `llm_models_region` vars
      (`phase1/variables.tf`) and outputs `llm_models_bucket[_hostname]`,
      `llm_models_access_key`, `llm_models_secret_key` (sensitive)
      (`phase1/outputs.tf`)
- [x] Document in `terraform.tfvars.example`
- [x] `terraform validate` + `fmt` pass; plan verified: prod creates
      `mothertree-models-prod` + `tf-managed-mothertree-models-prod`, dev skips
- [ ] **Apply**: `manage_infra -e prod --phase1` and `-e prod-eu --phase1`, then
      copy each `terraform output -raw llm_models_secret_key` into the infra
      tenant secrets as `llm.s3_secret` (Phase 1)

### Phase 1 — Infra config + secrets (dev/prod/prod-eu)
- [x] Add `llm:` block to `config/platform/infra/{dev,prod,prod-eu}.config.yaml`:
      `model`, `s3_bucket`, `s3_endpoint`, `s3_region`, `s3_prefix: ollama`
      (us-lax-1 for dev/prod, nl-ams-1 for prod-eu)
- [ ] Add `llm.s3_key` / `llm.s3_secret` to the infra tenant secrets for
      prod/prod-eu (dev already done in Phase 0). Blocked on Phase 0b apply —
      values come from `terraform output -raw llm_models_secret_key` after
      `manage_infra -e prod/prod-eu --phase1`, then the vault must be rebuilt
      (`scripts/build-deploy-vaults.sh prod/prod-eu`). Until then, deploy-llm.sh
      fail-fasts on prod/prod-eu (loud warning, no cluster changes).

### Phase 2 — `scripts/lib/infra-config.sh`
- [x] Config loader (~line 149, after `LLM_MODEL`): load
      `LLM_S3_BUCKET` / `LLM_S3_ENDPOINT` / `LLM_S3_REGION` / `LLM_S3_PREFIX`
- [x] Secrets loader (~line 422, after pgbackrest secrets): load
      `LLM_S3_KEY` / `LLM_S3_SECRET`; deploy-llm.sh validates them fail-fast
      before any cluster mutation (the shared loader stays lenient so unrelated
      infra deploys never break)

### Phase 3 — Manifests
- [x] New `apps/manifests/llm/ollama-model-seed-job.yaml`: initContainer `pull`
      (ollama image: `ollama serve &` → wait `/api/tags` → `ollama pull $LLM_MODEL`),
      main container `upload` (pinned `amazon/aws-cli`, `aws s3 sync` up),
      shared emptyDir, `restartPolicy: OnFailure`, `envFrom` `ollama-s3`
- [x] Edit `apps/manifests/llm/ollama.yaml.tpl`: volume → `emptyDir: {}`
      (disk-backed), add `restore-models` initContainer (aws-cli `aws s3 sync`
      down, no `--delete`), strip `ollama pull` from main command → `ollama serve`,
      `strategy: RollingUpdate` (`maxUnavailable: 0`), `envFrom` `ollama-s3`

### Phase 4 — `apps/deploy-llm.sh`
- [x] Delete the PVC creation + `OLLAMA_STORAGE_VALUE` block and the
      template placeholder
- [x] Create `ollama-s3` Secret from `LLM_S3_*`, wrapped in `mt_apply`
- [x] Gate + apply seed Job non-blocking: no `kubectl wait`. The bucket check
      uses a throwaway `kubectl run` pod with the pinned aws-cli image
      (no local aws CLI dependency) — model manifest present in the bucket ⇒
      skip; Job already applied ⇒ skip; otherwise apply. A failed check
      degrades to applying the (idempotent) seed Job.
- [x] Keep `/api/tags` post-deploy verification

### Phase 5 — Deploy + verify (dev → prod/prod-eu)
- [x] Bucket seeded: `ollama/blobs/` + `ollama/manifests/` present in
      `mothertree-models` (seeded by the validation seed Job, 2026-08-07). A
      full `deploy_infra -e dev` run with the repo code is still pending — the
      gate will skip re-seeding since the manifest is already in the bucket.
- [x] `kubectl rollout restart deploy/ollama -n infra-llm` → ready in **31s**
      (validated, hand-applied), model listed in `/api/tags`
- [x] `kubectl get pvc,pv -n infra-llm` empty (validated); no deploy blocking on
      the model pull
- [ ] Replicate to prod/prod-eu (Phase 0b apply → add `llm.s3_*` to vault →
      `deploy_infra`) with the same checks
