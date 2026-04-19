# Stalwart Encryption-at-Rest API Reference

## Overview
When a user pastes their OpenPGP public key into the web UI at `/account/crypto`, 
it enables encryption-at-rest for their mailbox. This can be done programmatically.

## API Endpoint
- **Internal**: `http://stalwart.tn-{tenant}-mail.svc.cluster.local:8080/api/account/crypto`
- **External**: `https://mail.{env}.{domain}/api/account/crypto` (via webmail ingress)

## Authentication
- Uses **Basic Auth** with the user's **username** (not email) and their **app password**
- NOT the admin password - must use a user principal with app password
- Format: `Authorization: Basic base64(username:app_password)`
- **Important**: Use the username (e.g., `marje2`) NOT the full email address (e.g., `marje2@dev.mother-tree.org`) - this is because Stalwart stores user accounts keyed by the principal name, which is the username portion

## Get Current Crypto Settings
```bash
GET /api/account/crypto
```

Response:
```json
{"data": {"type": "disabled"}}
# or when enabled:
{"data": {"type": "pGP", "algo": "Aes256", "certs": "...", "allow_spam_training": true}}
```

## Enable Encryption with OpenPGP
```bash
POST /api/account/crypto
Content-Type: application/json

{
  "type": "pGP",
  "algo": "Aes256",
  "certs": "<PGP_PUBLIC_KEY>",
  "allow_spam_training": true
}
```

**Important**:
- Use `pGP` NOT `pgp` (case-sensitive!)
- Include `allow_spam_training` field (required)
- Newlines in the certificate must be escaped (use `jq -Rs .` to escape)

## Example (dev, mothertree tenant)

### Step 1: Get an app password for a user
Users can create app passwords in the account portal, or you can create one via admin API.

### Step 2: Get crypto settings
```bash
# Use username (without domain), not email address
curl -s "http://localhost:8080/api/account/crypto" \
  -u "username:app_password" | jq .
```

### Step 3: Enable encryption
```bash
PGP_KEY=$(cat public-key.pub | jq -Rs .)
curl -s -X POST "http://localhost:8080/api/account/crypto" \
  -u "username:app_password" \
  -H "Content-Type: application/json" \
  -d "{\"type\": \"pGP\", \"algo\": \"Aes256\", \"certs\": $PGP_KEY, \"allow_spam_training\": true}" | jq .
```

## Disable Encryption
```bash
POST /api/account/crypto
{"type": "disabled"}
```

## Key Details
- Encryption only applies to **new emails** received after enabling
- Existing emails are NOT encrypted (encryption-at-rest, not encryption-of-existing)
- The private key stays with the user (their email client has it)
- The server stores the public key and uses it to encrypt incoming mail