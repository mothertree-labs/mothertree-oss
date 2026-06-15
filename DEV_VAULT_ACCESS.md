# Dev Vault Access — sharing dev secrets without exposing prod

The CI deploy vaults (`config/platform/ci/deploy-vault-<env>.vault`) are
Ansible Vault-encrypted tarballs holding kubeconfigs, terraform outputs, and
per-tenant secrets. They are the **only** committed copy of secrets — the
plaintext `*.secrets.yaml` files are gitignored.

By default every vault (dev, prod, prod-eu) was encrypted with a **single**
shared password, so handing that password to a contributor would expose prod.
To let a contributor add/update **dev** secrets safely, the **dev vault is
re-keyed with its own password**. That dev password unlocks *only*
`deploy-vault-dev.vault`; prod/prod-eu stay under the shared operator password.

- **dev** → its own password (LastPass note `mothertree-dev-vault-password`)
- **prod / prod-eu** → the shared password (LastPass note `7375668101991863677`,
  Woodpecker secret `deploy_vault_password`) — unchanged

---

## Part A — One-time operator setup (re-key dev)

Run once, from an operator machine with LastPass + the repo checked out.

1. **Generate a dev password and store it in LastPass.**
   ```bash
   openssl rand -base64 24            # copy the output
   ```
   Create a LastPass **Secure Note** named exactly `mothertree-dev-vault-password`
   and paste the password as the note body.

2. **Re-key the dev vault** (encrypts `deploy-vault-dev.vault` with the new
   dev password; prod/prod-eu untouched):
   ```bash
   ./scripts/build-deploy-vaults.sh dev
   ```
   Then **commit the re-keyed blob** in the `config/platform` submodule — CI
   decrypts the vault from this committed copy, so the re-key isn't live until
   it's merged:
   ```bash
   cd config/platform && git add ci/deploy-vault-dev.vault && git commit -m "dev: re-key vault" && git push
   cd ../.. && git add config/platform && git commit -m "chore(config): bump platform — dev vault re-key"
   ```
   > The second commit is required: CI clones with `git submodule update --init`
   > (no `--remote`), so it checks out the config/platform commit **pinned in the
   > mothertree-oss tree**. Bumping that pointer in a mothertree-oss PR is what
   > makes the new vault live — committing inside config/platform alone is not
   > enough.

3. **Acceptance test — prove the password is dev-only.** Both lines must behave
   as labelled, against the real committed blobs:
   ```bash
   DEV_PW=$(lpass show --note mothertree-dev-vault-password)

   # MUST FAIL — the dev password cannot open prod:
   ansible-vault decrypt config/platform/ci/deploy-vault-prod.vault \
     --vault-password-file <(printf '%s' "$DEV_PW") --output - >/dev/null \
     && echo "DANGER: dev pw opened prod" || echo "OK: dev pw cannot open prod"

   # MUST SUCCEED — the dev password opens dev:
   ansible-vault decrypt config/platform/ci/deploy-vault-dev.vault \
     --vault-password-file <(printf '%s' "$DEV_PW") --output - >/dev/null \
     && echo "OK: dev pw opens dev" || echo "FAIL: dev pw cannot open dev"
   ```

4. **Let CI decrypt the re-keyed dev vault.** Add the dev password to the
   **private, gitignored** `config/platform/ci/ansible-vars.yml`:
   ```yaml
   deploy_vault_password_dev: "<the dev password>"
   ```
   > Never commit the real value. It belongs only in the gitignored
   > `ansible-vars.yml`. Ansible writes it to
   > `/home/woodpecker/deploy-vaults/dev-vault-pass` (0600) with `no_log`.

5. **Re-provision the CI host** to push the **dev password file**
   (`dev-vault-pass`). The vault *blob* is no longer pushed to the host — CI
   reads it from the committed copy (step 2) — but the password that unlocks it
   still comes from the host file written by Ansible, so reprovision whenever
   the dev password changes:
   ```bash
   ./ci/scripts/provision-ci.sh --ansible-only
   ```

### Why there's no flag-day
`ci_decrypt_vault` (in `ci/scripts/ci-lib.sh`) decrypts the dev vault by trying
the dev password **first** and the shared password as a fallback. So dev
deploys keep working even if steps 2 and 5 land out of order. Once stable, the
shared fallback for dev can be dropped so a misconfigured dev vault fails loud
instead of silently decrypting under the prod password.

### Rotating the dev password later
Update the LastPass note, repeat steps 2–5. Re-share with the contributor.

---

## Part B — Contributor workflow (add/update dev secrets)

You need: the **dev vault password** (from the operator) and **write access to
the `config/tenants` and `config/platform` submodules**. You do **not** need
LastPass, the dev kubeconfig, terraform outputs, or tf-state credentials.

You deploy via CI only — never directly.

1. **Get the current plaintext dev secrets for your tenant.** These files are
   gitignored, so a fresh clone won't have them. To **update an existing**
   tenant, extract the current copy from the vault first (the dev password
   decrypts it):
   ```bash
   DEV_PW='<dev-vault-password>'
   TMP=$(mktemp -d)
   ansible-vault decrypt config/platform/ci/deploy-vault-dev.vault \
     --vault-password-file <(printf '%s' "$DEV_PW") --output - | tar xz -C "$TMP"
   cp "$TMP/tenants/<tenant>/dev.secrets.yaml" config/tenants/<tenant>/dev.secrets.yaml
   rm -rf "$TMP"
   ```
   (For a brand-new tenant or a new key, just create the file directly.)
   Then make your edit — it stays local and is never committed in plaintext:
   ```bash
   $EDITOR config/tenants/<tenant>/dev.secrets.yaml
   ```

2. **Patch it into the dev vault** — this decrypts the existing vault, swaps in
   only the tenant(s) you name, preserves everything else, and re-encrypts with
   the same dev password:
   ```bash
   MT_VAULT_PASSWORD='<dev-vault-password>' \
     ./scripts/build-deploy-vaults.sh dev --update-secrets --tenant <tenant>
   ```
   `--tenant` is repeatable; at least one is required. Only the named tenants
   are touched, so a stale local copy of another tenant can't overwrite the
   vault.

   > Prefer not to put the password in your shell history? Use a file:
   > `MT_VAULT_PASSWORD_FILE=~/.mt-dev-vault-pass ./scripts/build-deploy-vaults.sh dev --update-secrets --tenant <tenant>`

3. **Commit the updated vault blob** in the `config/platform` submodule, then
   **bump the submodule pointer** in the mothertree-oss superproject and open a
   PR there:
   ```bash
   cd config/platform
   git add ci/deploy-vault-dev.vault
   git commit -m "dev: update <tenant> secrets"
   git push                                   # push the config/platform commit
   cd ../..
   git add config/platform                    # record the new pointer
   git commit -m "chore(config): update <tenant> dev secrets"
   ```
   The second commit (the pointer bump) is the one that matters: CI clones with
   `git submodule update --init` (no `--remote`), so it checks out the
   config/platform commit **pinned in the mothertree-oss tree** — not the tip of
   the submodule branch. Open the **mothertree-oss** PR with that pointer bump.
   Once merged, the **next pipeline run decrypts this committed vault directly**
   and deploys the change to dev — no operator reprovision of the CI host is
   needed (GitHub issue #463).

### What the dev password actually grants
The dev password decrypts the **entire** dev vault — the dev kubeconfig,
terraform outputs, tf-state credentials, and **every** tenant's dev secrets —
not just the tenant you edit. Patch mode also exposes all of that transiently
in a temp staging dir on your machine while it runs. It does **not** grant any
access to prod or prod-eu.
