---
name: debug-email
description: "Debug email delivery — check DNS records, Postfix routing, DKIM signing, Stalwart status"
allowed-tools: ["Bash(kubectl *)", "Bash(dig *)", "Bash(nslookup *)", "Bash(curl *)", "Read", "Grep"]
---

# Email Chain Debugger

## Instructions

Debug the email delivery chain for a domain. The user may specify a domain (e.g., `example.com`) or a tenant name. Default domain: `example.com`.

### Step 1: DNS Records

Check all email-related DNS records:

```bash
# MX record
dig MX <domain> +short

# SPF record
dig TXT <domain> +short | grep spf

# DKIM record
dig TXT default._domainkey.<domain> +short

# DMARC record
dig TXT _dmarc.<domain> +short

# Mail server A record
dig A mail.example.com +short

# Autodiscovery SRV records
dig SRV _imaps._tcp.<domain> +short
dig SRV _submission._tcp.<domain> +short
dig SRV _submissions._tcp.<domain> +short
```

**Expected**:
- MX -> `mail.example.com` (priority 10)
- SPF -> `v=spf1 a:mail.example.com a:mail.dev.example.com include:_spf.mx.cloudflare.net ~all`
- DKIM -> `v=DKIM1; k=rsa; p=<key>`
- DMARC -> `v=DMARC1; p=quarantine; ...`
- SRV records -> `mail.example.com` with tenant-specific ports

### Step 2: VPN Postfix -> K8s Postfix Connectivity

```bash
# Check K8s Postfix pod
kubectl get pods -n infra-mail -o wide
kubectl get svc -n infra-mail

# Check Postfix logs for recent activity
kubectl logs -n infra-mail -l app=postfix --tail=30
```

### Step 3: K8s Postfix Configuration

```bash
# Check relay domains (which domains are accepted)
kubectl exec -n infra-mail deploy/postfix -- cat /etc/postfix/relay_domains 2>/dev/null

# Check transport map (domain -> Stalwart routing)
kubectl exec -n infra-mail deploy/postfix -- cat /etc/postfix/transport 2>/dev/null

# Check main config
kubectl exec -n infra-mail deploy/postfix -- postconf relayhost mydomain myhostname 2>/dev/null
```

### Step 4: OpenDKIM Status

```bash
# Check OpenDKIM sidecar logs
kubectl logs -n infra-mail -l app=postfix -c opendkim --tail=20

# Check DKIM key secrets exist
kubectl get secrets -n infra-mail | grep dkim

# Check OpenDKIM config
kubectl get configmap opendkim-config -n infra-mail -o yaml 2>/dev/null | grep -A2 -E 'SigningTable|KeyTable'
```

### Step 5: Stalwart Mail Server

Find the tenant's Stalwart instance:

```bash
# Check Stalwart pod (replace <tenant> with actual tenant name)
kubectl get pods -n tn-<tenant>-mail -o wide
kubectl logs -n tn-<tenant>-mail -l app=stalwart --tail=30

# Check Stalwart service
kubectl get svc -n tn-<tenant>-mail
```

### Step 6: Mail Queue (if messages are stuck)

```bash
# Check Postfix mail queue
kubectl exec -n infra-mail deploy/postfix -- mailq 2>/dev/null

# Check deferred mail
kubectl exec -n infra-mail deploy/postfix -- find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l
```

## Output Format

```
## Email Debug Report: <domain>

### DNS Records
| Record | Status | Value |
|--------|--------|-------|
| MX | OK/MISSING/WRONG | ... |
| SPF | OK/MISSING/WRONG | ... |
| DKIM | OK/MISSING/WRONG | ... |
| DMARC | OK/MISSING/WRONG | ... |
| SRV (IMAPS) | OK/MISSING | ... |
| SRV (Submission) | OK/MISSING | ... |

### Mail Chain
| Hop | Status | Details |
|-----|--------|---------|
| K8s Postfix | RUNNING/DOWN | pod status, recent errors |
| OpenDKIM | RUNNING/DOWN | signing status |
| Transport Map | OK/MISSING | domain routing |
| Stalwart | RUNNING/DOWN | pod status, recent errors |

### Issues Found
- <issue description and suggested fix>

### Mail Queue
- Queued: <count>
- Deferred: <count>
```
