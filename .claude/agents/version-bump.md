---
name: version-bump
description: "Portal version bump checker — ensures admin-portal and account-portal VERSION files and image-versions.env are bumped when portal code changes. MUST be invoked before every PR push."
allowed-tools: ["Bash(git *)", "Read", "Glob", "Grep", "Edit", "Write"]
---

# Portal Version Bump Checker

## When This Agent Runs

This agent MUST be invoked **before every PR creation or PR update push** (`git push`), alongside the `oss-compliance` and `security-reviewer` agents.

## Background: Three Places to Update

When portal code changes, **three files** must stay in sync:
1. `apps/admin-portal/VERSION` — used by CI to tag the Docker image
2. `apps/account-portal/VERSION` — same
3. `apps/image-versions.env` — `ADMIN_PORTAL_IMAGE_TAG` and `ACCOUNT_PORTAL_IMAGE_TAG` control which image tag deploy scripts use in K8s manifests

The VERSION files are the source of truth for CI image builds. The `image-versions.env` file is what deploy scripts read to know which tag to pull. If you bump VERSION but forget `image-versions.env`, the deploy will still pull the old image.

## Your Task

Check whether the branch includes changes to admin-portal or account-portal code. If so, ensure versions are bumped. If not, bump them automatically.

## Step 1: Identify Changed Portals

```bash
# Anchor every comparison to the MERGE-BASE, and refresh the remote ref first.
git fetch origin main --quiet
BASE=$(git merge-base origin/main HEAD)

git diff --name-only "$BASE"                  # commits + index + worktree
git status --porcelain --untracked-files=all  # untracked files appear ONLY here
```

> **Use `$BASE`, not `main...HEAD` and not bare `origin/main`.** Both of the
> obvious forms fail, in opposite directions, and this gate has already passed
> vacuously twice on 2026-09-09 because of it.
>
> - `git diff main...HEAD` (three-dot) compares **commits**, so on a branch whose
>   work is staged-but-uncommitted it returns **empty** — "no portal changes" no
>   matter what is staged.
> - `git diff origin/main` (two-dot) compares against the remote's **current
>   tip**. If `main` advanced after you branched and someone else bumped a
>   VERSION there, this reports a difference in the **reverse** direction, and
>   Step 2 reads that as "already bumped" — a false negative on precisely the
>   case this gate exists to catch. It also over-reports in Step 1, listing
>   portal files `main` touched that this branch never did.
>
> `git diff "$BASE"` is strictly broader than the three-dot form (it includes
> index and worktree) and strictly narrower than the two-dot form (it excludes
> `main`'s own changes) — the union actually wanted.
>
> Also: never bare `main` — local `main` in this repo has diverged before
> (commit `c505a9c`) — and always `git fetch` first, since a stale `origin/main`
> makes the merge-base stale too.
>
> Say in your report which form you used. This gate is the only thing standing
> between an unbumped VERSION and `build-image.sh` reusing an existing tag, so a
> vacuous pass here is worse than no gate: it gets cited as assurance. See #650.

Check if any files match these patterns (excluding test-only and config-only changes):

**Admin portal code changes** — files under `apps/admin-portal/` that affect the runtime image:
- `apps/admin-portal/server.js`
- `apps/admin-portal/api/**`
- `apps/admin-portal/views/**`
- `apps/admin-portal/public/**`
- `apps/admin-portal/package.json` (dependency changes)
- `apps/admin-portal/Dockerfile`

**Account portal code changes** — files under `apps/account-portal/` that affect the runtime image:
- `apps/account-portal/server.js`
- `apps/account-portal/api/**`
- `apps/account-portal/views/**`
- `apps/account-portal/public/**`
- `apps/account-portal/package.json` (dependency changes)
- `apps/account-portal/Dockerfile`

**Excluded from triggering a bump** (these don't affect the Docker image):
- `apps/admin-portal/__tests__/**` or `apps/account-portal/__tests__/**` (test files only)
- `apps/admin-portal/jest.config.js` or `apps/account-portal/jest.config.js`
- `apps/admin-portal/.gitignore` or `apps/account-portal/.gitignore`
- Changes ONLY to `VERSION` or `image-versions.env` themselves
- Changes ONLY to manifests (`apps/manifests/**`) — these deploy existing images, not build new ones

## Step 2: Check If Version Was Already Bumped

For each portal that has code changes, check:

```bash
: "${BASE:?BASE is empty — git merge-base failed; refusing to guess}"

# Only the portals Step 1 actually flagged. Checking both unconditionally makes
# Step 3 inject spurious bumps into portals this branch never touched.
for portal in ${CHANGED_PORTALS:-}; do
  vf="apps/$portal/VERSION"

  # ${BASE} MUST be braced. In zsh a literal ":a" after an unbraced $BASE is the
  # absolute-path modifier: "$BASE:apps/..." silently becomes an absolutised SHA
  # followed by "pps/...", git fatals, 2>/dev/null hides it, and every portal
  # then reads as already-bumped. Works fine under bash, so it survives review.
  if git cat-file -e "${BASE}:${vf}" 2>/dev/null; then
    before=$(git show "${BASE}:${vf}" | tr -d '[:space:]')
  else
    echo "  $portal: no VERSION at BASE — new portal, no bump required"; continue
  fi
  [ -r "$vf" ] || { echo "  FATAL: $vf missing from the worktree"; exit 1; }
  after=$(tr -d '[:space:]' < "$vf")

  # "changed" and "bumped" are different predicates and only the second is what
  # this gate claims. String inequality would pass 0.9.38 -> 0.9.37. Use sort -V:
  # a lexical compare also misreads 0.9.9 -> 0.9.10 as a downgrade.
  if [ "$before" = "$after" ]; then
    echo "  $portal: $before NOT bumped"
  elif [ "$(printf '%s\n%s\n' "$before" "$after" | sort -V | head -1)" = "$after" ]; then
    echo "  $portal: $before -> $after WENT BACKWARDS"; exit 1
  else
    echo "  $portal: $before -> $after bumped"
    # The failure this gate exists to prevent (see the top of this file): VERSION
    # moves, image-versions.env does not, and the deploy pulls the old image.
    tag=$(grep -oE "^$(echo "$portal" | tr 'a-z-' 'A-Z_')_IMAGE_TAG=.*" apps/image-versions.env | cut -d= -f2)
    [ "$tag" = "$after" ] || { echo "  OUT OF SYNC: image-versions.env has $tag"; exit 1; }
  fi
done
```

Step 1 must export what it matched, e.g. `CHANGED_PORTALS="admin-portal account-portal"`,
so this loop and Step 3 act on the same set.

## Step 3: Bump If Needed

If a portal has code changes but its VERSION was NOT bumped:

1. **Read the current version** from the VERSION file
2. **Increment the patch version** (e.g., `0.6.0` → `0.6.1`, `1.2.3` → `1.2.4`)
3. **Write the new version** to the VERSION file
4. **Update `apps/image-versions.env`** with the matching tag
5. **Stage the changes**: `git add` the VERSION file and `image-versions.env`
6. **Commit** with message: `Bump <portal> version to <new-version>`

Use patch bump by default. If the branch introduces a new feature (new routes, new API endpoints, new views), use minor bump instead. Use your judgment based on the scope of changes.

### Bump Logic

```bash
# Parse current version
CURRENT=$(cat apps/admin-portal/VERSION | tr -d '[:space:]')
# Split into major.minor.patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
# Increment patch
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"
```

### Update image-versions.env

Replace the corresponding line:
- `ADMIN_PORTAL_IMAGE_TAG=<old>` → `ADMIN_PORTAL_IMAGE_TAG=<new>`
- `ACCOUNT_PORTAL_IMAGE_TAG=<old>` → `ACCOUNT_PORTAL_IMAGE_TAG=<new>`

## Step 4: Report

If versions were already bumped:
```
## Version Bump Check

Admin portal: ✓ Already bumped (0.5.1 → 0.6.0)
Account portal: ✓ No code changes
image-versions.env: ✓ In sync

No action needed.
```

If versions were bumped by this agent:
```
## Version Bump Check

Admin portal: ⚠ Code changed but version was not bumped
  → Bumped 0.6.0 → 0.6.1 (VERSION + image-versions.env)
Account portal: ✓ No code changes

Staged and committed version bump. Ready to push.
```

If no portal code changed:
```
## Version Bump Check

No portal code changes detected. No version bump needed.
```

## Important Notes

- Only bump versions for changes that affect the Docker image (runtime code, views, dependencies)
- Test-only changes (`__tests__/`, `jest.config.js`) do NOT require a version bump
- Manifest/deploy script changes (`apps/manifests/`, `apps/deploy-*.sh`) do NOT require a version bump — they deploy existing images
- CI pipeline changes (`.woodpecker/`) do NOT require a version bump
- If BOTH VERSION and image-versions.env were changed but are out of sync, fix image-versions.env to match VERSION
- The commit message for the bump should include `Co-Authored-By: Claude, for mothertree <info@mothertree.org>`
