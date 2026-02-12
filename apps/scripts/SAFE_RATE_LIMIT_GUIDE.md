# Safe Rate Limit Configuration Guide

## The Problem

The Synapse Helm chart's `extraConfig` section is **replaced entirely** by environment-specific files. This means:
- If you add rate limits to `dev/synapse.yaml`, you MUST also add them to `prod/synapse.yaml`
- Missing any existing config keys will break deployment
- YAML syntax errors will cause pods to crash loop

## Safe Process (Step-by-Step)

### Step 1: Validate Current State

```bash
# Check what's currently in your configs
cd apps
./scripts/validate-synapse-config.sh dev
```

### Step 2: Review Current extraConfig

Look at what's currently in `apps/environments/dev/synapse.yaml`:
- `turn_uris`
- `turn_shared_secret`
- `account_threepid_delegates`
- `email`
- `oidc_providers`

**ALL of these must remain** when adding rate limits!

### Step 3: Add Rate Limits (Manual - Safest)

Edit `apps/environments/dev/synapse.yaml` and add rate limits to the `extraConfig` section:

```yaml
extraConfig:
  # ... existing config (turn_uris, turn_shared_secret, etc.) ...
  
  # Rate limiting configuration
  rc_message:
    per_second: 2.0      # Allow 2 messages per second (default: 0.2)
    burst_count: 50      # Allow bursts of up to 50 messages (default: 10)
  
  rc_login:
    address:
      per_second: 1.0     # Allow 1 login per second per IP (default: 0.003)
      burst_count: 10     # Allow bursts of up to 10 logins (default: 5)
    account:
      per_second: 0.5     # Allow 0.5 logins per second per account (default: 0.003)
      burst_count: 5      # Allow bursts of up to 5 logins (default: 5)
    failed_attempts:
      per_second: 1.0     # Allow 1 failed login per second (default: 0.17)
      burst_count: 10      # Allow bursts of up to 10 failed logins (default: 3)
  
  rc_joins:
    local:
      per_second: 0.5     # Allow 0.5 joins per second (default: 0.1)
      burst_count: 20      # Allow bursts of up to 20 joins (default: 10)
    remote:
      per_second: 0.1      # Allow 0.1 remote joins per second (default: 0.01)
      burst_count: 10      # Allow bursts of up to 10 remote joins (default: 10)
```

### Step 4: Copy to Prod (After Testing Dev)

**DO NOT** add to prod until dev is tested! But when ready, copy the same rate limit section to `apps/environments/prod/synapse.yaml`.

### Step 5: Validate Before Deploying

```bash
# Validate YAML syntax and Helm template generation
cd apps
./scripts/validate-synapse-config.sh dev

# Check the generated template
cat /tmp/synapse-template.yaml | grep -A 20 "rc_"
```

### Step 6: Deploy to Dev First

```bash
cd apps
helmfile -e dev sync -l name=matrix-synapse
```

### Step 7: Monitor Deployment

```bash
# Watch the pod come up
kubectl -n matrix get pods -l app.kubernetes.io/name=matrix-synapse -w

# Check logs for errors
kubectl -n matrix logs -l app.kubernetes.io/name=matrix-synapse -f

# Verify config was loaded
kubectl -n matrix exec <pod-name> -- python3 -c "import yaml; f=open('/synapse/config/homeserver.yaml'); c=yaml.safe_load(f); import json; print(json.dumps(c.get('rc_message', {}), indent=2))"
```

### Step 8: Test Rate Limits

Try logging in multiple times quickly - you should see fewer 429 errors.

### Step 9: Only Then Deploy to Prod

After dev is stable for at least 24 hours, repeat steps 4-7 for prod.

## Automated Option (Use with Caution)

If you want to use the automated script:

```bash
cd apps
./scripts/add-rate-limits.sh
```

**But still validate and test!**

## Rollback Plan

If something goes wrong:

1. **Restore from backup:**
   ```bash
   cd apps/environments/dev
   mv synapse.yaml.backup synapse.yaml
   ```

2. **Or revert with git:**
   ```bash
   git checkout apps/environments/dev/synapse.yaml
   ```

3. **Redeploy:**
   ```bash
   cd apps
   helmfile -e dev sync -l name=matrix-synapse
   ```

## Common Mistakes to Avoid

1. ❌ **Adding rate limits to only one environment file**
2. ❌ **Removing existing extraConfig keys** (turn_uris, oidc_providers, etc.)
3. ❌ **YAML indentation errors** (use 2 spaces, not tabs)
4. ❌ **Deploying to prod before testing in dev**
5. ❌ **Not validating before deploying**

## Rate Limit Values Explained

- `per_second`: Average rate over time (token bucket algorithm)
- `burst_count`: Maximum actions allowed in quick succession before throttling

Higher values = more permissive, but also more resource usage and abuse risk.

## Need Help?

If deployment fails:
1. Check pod logs: `kubectl -n matrix logs <pod-name>`
2. Check pod status: `kubectl -n matrix describe pod <pod-name>`
3. Validate config: `./scripts/validate-synapse-config.sh dev`
4. Rollback and try again











