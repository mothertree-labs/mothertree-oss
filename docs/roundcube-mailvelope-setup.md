# Roundcube + Mailvelope + Stalwart: PGP Encryption Setup

## Overview

This documents the changes required to enable end-to-end PGP encryption for Roundcube webmail backed by Stalwart mail server, so that:
- Incoming emails are encrypted at rest on disk (Stalwart)
- Sent folder copies are also encrypted at rest (Stalwart)
- Decryption happens client-side in the browser via Mailvelope (private key never leaves the browser)

---

## 1. Stalwart Configuration

### 1.1 Enable PGP Encryption at Rest

Upload the user's public key via the Stalwart API:

```bash
curl -sS -X POST \
    -u "${USERMAIL}:${APP_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"pGP\",\"algo\":\"Aes256\",\"certs\":${PGP_KEY_JSON},\"allow_spam_training\":true}" \
    "${STALWART_API_URL}/api/account/crypto"
```

This encrypts all **incoming** messages before writing to disk.

### 1.2 Enable Encryption for IMAP APPEND (Sent Folder)

By default, messages saved to the Sent folder via IMAP APPEND (what Roundcube does) are **not** encrypted. Enable it explicitly in Stalwart config:

```toml
[email.encryption]
append = true
```

Without this, Sent folder copies are stored in plaintext even if incoming mail is encrypted.

---

## 2. Roundcube Configuration

### 2.1 Remove the `mailvelope_client` Plugin

The third-party `posteo/mailvelope_client` plugin is **incompatible** with modern Roundcube (1.2+) and jQuery 3.x. It crashes on init with:

```
Uncaught TypeError: $(...).size is not a function
```

Remove it from the plugins list. Roundcube has native Mailvelope support since version 1.2 — no plugin needed.

```php
$config['plugins'] = [
    'archive',
    'zipdownload',
    'managesieve',
    'markasjunk',
    // ... your other plugins
    // do NOT include 'mailvelope_client'
    // do NOT include 'enigma' (server-side, stores private keys on server)
];
```

### 2.2 Enable Mailvelope Main Keyring

Add this to your Roundcube config:

```php
$config['mailvelope_main_keyring'] = true;
```

> **Note:** Due to a bug in Roundcube, this setting is only passed to the browser JS environment during **compose**, not during **message view**. As a result, Roundcube uses the per-user keyring (named after `rcmail.env.user_id`) for decryption rather than the Mailvelope main keyring. See section 3 for how to handle this correctly.

---

## 3. Mailvelope Browser Extension Setup

These steps must be performed by each user in their browser.

### 3.1 Install Mailvelope

Install the Mailvelope extension for [Firefox](https://addons.mozilla.org/firefox/addon/mailvelope/) or [Chrome/Edge](https://chrome.google.com/webstore/detail/mailvelope/).

> **Mobile limitation:** Mailvelope does not work on mobile browsers. Users on Android/iOS need a native app (e.g. FairEmail or K-9 Mail) instead.

### 3.2 Generate or Import Your Keypair

In the Mailvelope extension settings:
- Go to **Key Management**
- Either **Generate** a new keypair for your email address, or **Import** an existing private key

### 3.3 Authorize Your Roundcube Domain

1. Navigate to your Roundcube inbox
2. Click the **Mailvelope icon** in the browser toolbar
3. Select **"Authorize this domain"**
4. In the dialog, leave the domain pattern as detected (add port if your URL has one, e.g. `:8080`)
5. Enable the **API toggle**
6. Click **OK**
7. Hard reload the page (`Ctrl+Shift+R`)

### 3.4 Enable Mailvelope in Roundcube Settings

1. Go to **Roundcube Settings → Preferences → Encryption**
2. Enable **"Use Mailvelope main keyring"**
3. Save

### 3.5 Import Your Private Key into the Correct Keyring

This is the critical step. Roundcube uses a **per-user keyring** (not the Mailvelope main keyring) for message decryption. The keyring identifier is your Roundcube `user_id` (an opaque string like `C5ygkAZAz9OMOsPw`).

To find the correct keyring identifier, open the browser DevTools console on the Roundcube page and run:

```js
rcmail.env.user_id
```

Then in the Mailvelope extension:
1. Open **Mailvelope settings → Key Management**
2. Use the **keyring selector dropdown** to switch to the keyring matching your `user_id`
3. **Import your private key** into that keyring (not the default/main keyring)
4. Verify it worked:

```js
window.mailvelope.getKeyring('YOUR_USER_ID_HERE')
  .then(kr => kr.hasPrivateKey('YOUR_KEY_FINGERPRINT'))
  .then(result => console.log('has private key:', result))
```

This should return `true`.

### 3.6 Trigger Session Refresh

Roundcube stores PGP/MIME capability in the PHP session. After setting up Mailvelope, the session must be refreshed so Roundcube knows to pass encrypted message content to the browser instead of showing the "Sorry!" fallback.

**Log out and log back in** to Roundcube. After re-login, encrypted messages will be decrypted automatically by Mailvelope in the message view.

---

## 4. How It Works (Summary)

```
Incoming email
    → Stalwart receives via SMTP
    → Encrypts with user's public key (stored via API)
    → Stores encrypted blob on disk
    → User opens in Roundcube
    → Roundcube passes encrypted content to browser
    → Mailvelope decrypts using private key (stored in browser extension only)
    → User reads plaintext

Outgoing email (Sent copy)
    → Roundcube sends via SMTP
    → Roundcube saves copy to Sent folder via IMAP APPEND
    → Stalwart intercepts APPEND (because append = true)
    → Encrypts with user's public key before writing to disk
    → Private key never touches the server
```

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Sent folder messages are in plaintext | `[email.encryption] append = true` not set in Stalwart | Add the config and restart Stalwart |
| `$(...).size is not a function` in console | Old `mailvelope_client` plugin loaded | Remove plugin from Roundcube config |
| `window.mailvelope` is undefined | Domain not authorized in Mailvelope | Follow section 3.3 |
| `rcmail.mailvelope_keyring` is undefined | Session has stale `pgpmime=0` capability | Log out and log back in |
| `hasPrivateKey` returns `false` | Private key imported into wrong keyring | Import into the `user_id` keyring (section 3.5) |
| "No valid armored block found" | Roundcube rendered "Sorry!" fallback before Mailvelope could decrypt | Session refresh needed (section 3.6) |
| "This is an encrypted message and can not be displayed. Sorry!" | `pgpmime=0` in session — Roundcube not passing ciphertext to browser | Log out and log back in |
