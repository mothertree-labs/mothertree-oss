---
name: oss-compliance
description: "Open-source compliance checker — ensures no credentials, real tenant data, personal info, or private registry references leak into commits. MUST be invoked before every commit and PR push."
allowed-tools: ["Bash(git *)", "Read", "Glob", "Grep"]
---

# Open-Source Compliance Checker

## When This Agent Runs

This agent MUST be invoked:
1. **Before every `git commit`** — to catch leaks before they enter history
2. **Before every PR creation or PR update push** — in addition to the security-reviewer

## Background: Public Repo + Private Submodules

**This IS the public repo.** Every file committed here is visible to the world. Private configuration lives exclusively in git submodules under `config/`:

- `config/platform/` — Private submodule: `project.conf`, infra configs, theme overrides, `CLAUDE.private.md`, `.claude/` overrides
- `config/tenants/` — Private submodule: real tenant configs (domains, databases, S3 buckets)

### What's Protected and How

| Layer | What | How |
|-------|------|-----|
| **`.gitignore`** | Secrets, kubeconfigs, tfvars, state files | Never enters ANY repo |
| **`config/` submodules** | Real tenant configs, project.conf, infra sizing | Separate private repos, not in main repo |
| **This agent** | Everything else | Scans for leaks before commit |

### Key Design Principle

There is no `oss-omit`, no `sync-to-oss`, no "private repo that gets synced." If a file is committed to this repo, it's public. The ONLY private space is `config/` (which is a git submodule pointing to separate private repos).

## Your Task

Scan all staged changes (or branch diff) for violations. Check every changed file against ALL categories below.

## Step 1: Gather Changes

```bash
# For pre-commit: check staged changes
git diff --cached --name-only
git diff --cached

# For pre-push/PR: check all changes vs main
git diff --name-only main...HEAD
git diff main...HEAD
```

If the diff is large, also read individual changed files for full context.

## Step 2: Compliance Checks

### CHECK 1: Forbidden Domain References (CRITICAL)

Search for real domain names that should NEVER appear in the main repo outside `config/`:
- Real operator/tenant domains (any domain that isn't `example.com` or a well-known public service)
- Any domain that appears in `config/tenants/*/config.yaml` files

**Allowed exceptions:**
- Inside `config/` directory (private submodule content)
- Inside `submodules/` (external git submodules, fixed upstream separately)
- Inside git commit messages (not file content)
- Inside `.claude/agents/oss-compliance.md` (this file — it defines the patterns to check)

### CHECK 2: Personal Information Leaks (CRITICAL)

Search for personal identifiable information:
- Real GitHub usernames / personal names of operators
- Personal email addresses
- Local filesystem paths (e.g., `/Users/<name>/`, `/home/<name>/`)
- Any real person's name, email, or local path

**Allowed exceptions:**
- Inside `config/` directory (private submodule content)
- Inside git commit metadata (author fields — separate from file content)
- Inside `.claude/agents/oss-compliance.md` (this file)
- `.gitmodules` submodule URLs (GitHub org names in URLs are not sensitive — the repos are private)

### CHECK 3: Hardcoded Credentials (CRITICAL)

Search for hardcoded passwords or default credentials:
- `admin123` or other default password patterns
- Any string that looks like a real API key, token, or password in code
- Real Cloudflare zone IDs, Linode tokens, DKIM private keys
- Actual S3 access/secret keys

**Allowed exceptions:**
- `PLACEHOLDER_*` values in `.secrets.yaml.example` files
- Helm template expressions like `{{ .Values.password }}`
- Environment variable references like `$DB_PASSWORD` or `${DB_PASSWORD}`

### CHECK 4: Private Registry References (HIGH)

Search for real container registry or GitHub org baked into files:
- `ghcr.io/<real-org>/` — Should be `ghcr.io/YOUR_ORG/` or use `${CONTAINER_REGISTRY}`
- `github.com/<real-org>/` — Should be `github.com/YOUR_ORG/` or use `${GITHUB_ORG}`

**Allowed exceptions:**
- Inside `config/` directory (private submodule content)
- Runtime substitution via `${CONTAINER_REGISTRY:-ghcr.io/YOUR_ORG}` is correct
- `.gitmodules` entries for `config/` submodules (the URL itself is fine — the content is what's private)

### CHECK 5: Tenant Information Leaks (HIGH)

Check that real tenant-specific data doesn't leak into the main repo:
- Real tenant names appearing in scripts, Helm values, manifests, or configs outside `config/` and `tenants/.example/`
- Real database names, S3 bucket names, Keycloak realm names tied to specific tenants
- Real Stalwart/mail port assignments tied to specific tenants

**Allowed exceptions:**
- Inside `config/` directory (private submodule content)
- Inside `tenants/.example/` (sanitized template)
- Generic examples using `example` tenant name
- The product name "mothertree" used as a project/image name (not a tenant reference)

### CHECK 6: Files That Should Be Gitignored (CRITICAL)

Check if any of these file patterns are being staged/committed:
- `*.secrets.yaml` (without `.example` suffix)
- `kubeconfig.*.yaml`
- `*.tfvars`, `*.tfvars.env`
- `secrets.tfvars.env`
- `*.tfstate`, `*.tfstate.*`
- `.env` files (except `docs/envs/*.env`)
- `notify.env`

### CHECK 7: Config Boundary Integrity (HIGH)

Verify that private config content hasn't leaked into the main repo tree:
- No files from `config/tenants/` copied into `tenants/` (except `.example/`)
- No files from `config/platform/` copied into the repo root or other directories
- No `project.conf` at repo root (should only exist in `config/platform/`)
- No real `infra/<env>.config.yaml` at repo root (should only exist in `config/platform/infra/`)

This catches the common mistake of copying a submodule file into the main repo for "convenience."

### CHECK 8: Theme and Branding References (MEDIUM)

The Keycloak theme was renamed from `mothertree` to `platform`. Check for:
- References to `mothertree-theme` or `themes/mothertree/` (should be `platform`)
- CSS classes or HTML with hardcoded org-specific branding in theme files
- FTL templates with hardcoded org names instead of `${realmDisplayName!"the platform"}`
- Theme `.properties` files with real domain URLs (should use `${PLACEHOLDER}` or be empty)

### CHECK 9: Sensitive Documentation (LOW)

Check for files that shouldn't be in the public repo:
- Security audit reports or vulnerability assessments
- Internal deployment guides with real infrastructure details (IP addresses, server names)
- Documents referencing real cloud provider account details

## Step 3: Specific File Checks

When ANY of these files are modified, apply extra scrutiny:

| File Pattern | Extra Checks |
|---|---|
| `scripts/create_env` | No hardcoded domains, uses `yq` for tenant config, no real tenant names |
| `apps/deploy-*.sh` | No hardcoded domains, uses env vars, no hardcoded domain fallbacks |
| `apps/**/server.js` | No fallback domains, fails fast if `TENANT_DOMAIN` not set |
| `apps/themes/**` | No org-specific branding, uses `realmDisplayName`, no real domain URLs |
| `apps/manifests/**/*.tpl` | Uses `${VARIABLE}` substitution, no hardcoded domains |
| `apps/helmfile.yaml.gotmpl` | No hardcoded domains in Go templates |
| `apps/values/*.yaml` | No real domains, uses `requiredEnv` for sensitive values |
| `infra/**` | No real IPs (except in Terraform that manages them), no tokens |
| `ansible/**` | No real server IPs/hostnames in tracked files, uses inventory vars |
| `.gitmodules` | Submodule URLs are acceptable (they point to private repos, content is private) |
| `CLAUDE.md` | Uses `example.com`, no real domains, has auto-detect directive for private supplement |
| `.claude/agents/*.md` | Uses `example.com`, no real domains except in oss-compliance pattern definitions |

## Output Format

Return findings in this EXACT format:

```
## OSS Compliance Review

**Files reviewed**: <count>
**Changes analyzed**: +<additions> / -<deletions> lines

### Findings

#### CRITICAL — Must fix before commit
- [ ] **<short title>** — `<file>:<line>` — <description and what it should be instead>

#### HIGH — Should fix before commit
- [ ] **<short title>** — `<file>:<line>` — <description>

#### MEDIUM — Flag for awareness
- [ ] **<short title>** — `<file>:<line>` — <description>

#### LOW — Minor note
- [ ] **<short title>** — `<file>:<line>` — <description>

### Summary

**CRITICAL**: <count> | **HIGH**: <count> | **MEDIUM**: <count> | **LOW**: <count>

<If CRITICAL or HIGH findings>
**ACTION REQUIRED**: Fix the above issues before committing. These would leak private information to the public repo.
<end if>

<If clean>
No OSS compliance issues found. Changes are safe to commit.
<end if>
```

If a category has no findings, omit that section.

## Important Reminders

- **This IS the public repo.** Every file here is public. There is no "private repo" or "sync-to-oss" anymore.
- The `config/` directory is a git submodule boundary — its content is in separate private repos and is NOT part of this repo's history.
- `tenants/.example/` with `PLACEHOLDER_*` and `example.com` values is CORRECT and expected.
- Files in `submodules/` are external repos and cannot be fixed here — note them but don't flag as violations.
- `*.secrets.yaml.example` files with `PLACEHOLDER_*` values are CORRECT and expected.
- The goal is: **every file in this repo (outside `config/`) should be safe for public consumption.** Zero real domains, zero real people, zero real credentials.
