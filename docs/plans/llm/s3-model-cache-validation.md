# S3 Model Cache for Ollama — Dev Cluster Validation

Hand-apply the [s3-model-cache plan](./s3-model-cache.md) directly on the dev
cluster from the operator machine, **without editing the repo manifests**, to
validate the idea before committing the real changes. Mirrors the plan's
Phases 2–5, then leaves the cluster applied for the follow-up repo change.

## Context / current state (verified 2026-07-31)

- `kubeconfig.dev.yaml` is **stale** — points at a dead cluster endpoint
  (`<dead-endpoint>...-gw.linodelke.net`). Current dev cluster is LKE id
  **<redacted>** (`matrix-cluster-dev`, endpoint
  `<current-endpoint>...-gw.linodelke.net`).
  `config/platform/infra/terraform-outputs.dev.env` is also stale
  (`LKE_CLUSTER_ID=<stale-id>`).
- Bucket `mothertree-models` (us-lax-1) and key `<old-key-id>`
  (`mothertree-llm-dev`, scoped `read_write` to the bucket) exist, but the
  stored `llm.s3_secret` in `config/tenants/mothertree/dev.secrets.yaml` fails
  S3 auth (`SignatureDoesNotMatch`) — the access key matches the API, the
  secret is stale/rotated. **Decision: create a fresh key.**
- The deploy vault (`config/platform/ci/deploy-vault-dev.vault`) has no
  `llm:` block yet — rebuild it (`scripts/build-deploy-vaults.sh`) before CI
  needs `llm.s3_*`, but not required for local validation.
- Cluster state in `infra-llm`: `ollama` Deployment, 23 days old, `Recreate`
  strategy, `emptyDir` volume, pull-on-start command
  (`ollama pull llama3.2:1b`), model present (1.3 GB), no PVC.
- Local tooling: `docker` + `python3/boto3`; no `aws` CLI — use the pinned
  `amazon/aws-cli:2.22.35` image.
- **Watch item:** this machine's DNS resolves `us-lax-1.linodeobjects.com`
  IPv6-first and boto3 hung over IPv6 (IPv4 fine). The in-cluster seed/restore
  will prove whether pod networking has the same issue.

## Step 1 — Refresh dev kubeconfig

Rewrite `kubeconfig.dev.yaml` for cluster id **<redacted>** using the
documented vault→linode-cli command (or the validated curl route). Verify:
`kubectl --kubeconfig=kubeconfig.dev.yaml get pods -n infra-llm`.

## Step 2 — Create a fresh bucket key

- Linode API `POST /object-storage/keys`:
  - label `mothertree-llm-dev`
  - `limited: true`
  - `bucket_access`: bucket `mothertree-models`, `permissions: read_write`,
    cluster `us-lax-1`
- Update gitignored `config/tenants/mothertree/dev.secrets.yaml`:
  `llm.s3_key` / `llm.s3_secret`.
- Leave the old key `<old-key-id>` in place (revoke later if desired).

## Step 3 — Verify bucket access

```
docker run --rm -e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_ENDPOINT_URL=https://us-lax-1.linodeobjects.com -e AWS_REGION=us-lax-1 \
  amazon/aws-cli:2.22.35 s3 ls s3://mothertree-models/
```

- Confirms the pinned image tag exists.
- Confirms reachability + that `ollama/` prefix is empty.

## Step 4 — Create `ollama-s3` Secret

```
kubectl create secret generic ollama-s3 -n infra-llm \
  --from-literal=AWS_ACCESS_KEY_ID=... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=AWS_ENDPOINT_URL=https://us-lax-1.linodeobjects.com \
  --from-literal=AWS_REGION=us-lax-1
```

## Step 5 — Seed Job (plan §3)

Hand-written manifest in `/tmp`:

- initContainer `pull` (ollama 0.5.7): `ollama serve &` → wait `/api/tags` →
  `ollama pull llama3.2:1b` into shared emptyDir at `/root/.ollama`.
- main container `upload` (`amazon/aws-cli:2.22.35`):
  `aws s3 sync /root/.ollama s3://mothertree-models/ollama`.
- `restartPolicy: OnFailure`, both `envFrom: ollama-s3`.

`kubectl apply -f` then wait once (the one-time 15–20 min pull; this is manual
validation, so waiting is fine — `deploy_infra` will remain non-blocking).
Verify objects under `ollama/models/blobs/` + `ollama/models/manifests/`.

## Step 6 — Patch the `ollama` Deployment in place (plan §1)

- Add initContainer `restore-models`:
  `aws s3 sync --no-progress s3://mothertree-models/ollama/ /root/.ollama/`
  (no `--delete`), `envFrom: ollama-s3`.
- Replace main container command with plain `ollama serve`.
- Strategy: `Recreate` → `RollingUpdate` (`maxUnavailable: 0`).
- Volume stays disk-backed `emptyDir`.

## Step 7 — Verify (plan's acceptance criteria)

- `kubectl rollout restart deploy/ollama -n infra-llm` → pod ready in
  seconds/low-minutes (S3 restore), **not** 15–20 min; `ollama list` shows
  `llama3.2:1b`.
- `kubectl get pvc,pv -n infra-llm` → empty.
- Optional: `kubectl scale deploy/ollama --replicas=2` briefly to prove no
  volume-attach lock (RWO removal), then back to 1.

## Step 8 — Leave applied

- Keep the deployment + `ollama-s3` Secret; delete only the one-shot seed Job.
- Note: the repo still has the old manifest, so the next `deploy_infra -e dev`
  will revert these manual changes until the real repo changes land.

## Result

All checks passed (2026-08-07):
- Bucket `mothertree-models/ollama` seeded (blobs + manifests, incl. 1.32 GB weight blob).
- Fresh key (id `<fresh-key-id>`) works; old key `<old-key-id>` was stale
  (`SignatureDoesNotMatch`).
- Restore-from-S3 pod ready in **31s** vs 15–20 min cold pull; `llama3.2:1b` present in `/api/tags`.
- No PVC/PV in `infra-llm`; `RollingUpdate` (maxUnavailable 0) + 2-replica test on two nodes — no volume-attach lock.
- Pod networking reaches `us-lax-1.linodeobjects.com` with no IPv6 hang (local boto3 only).

The repo changes (Phases 1–4 of `s3-model-cache.md`) are now applied:
`config/platform/infra/*.config.yaml` `llm:` blocks, `scripts/lib/infra-config.sh`
`LLM_S3_*` loaders, `apps/manifests/llm/ollama.yaml.tpl` (emptyDir + restore
initContainer + `ollama serve` + RollingUpdate), new
`apps/manifests/llm/ollama-model-seed-job.yaml`, rewritten `apps/deploy-llm.sh`
(no PVC, `ollama-s3` secret via `mt_apply`, non-blocking seed-Job gate), and the
dev vault rebuilt with `llm.s3_*` (patch mode). The hand-applied cluster state
converges with the new manifests (one-time cosmetic reconcile on next deploy).
