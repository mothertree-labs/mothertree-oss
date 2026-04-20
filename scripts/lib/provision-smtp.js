#!/usr/bin/env node
/*
 * Provisions the per-tenant shared SMTP service-account principal in Stalwart
 * and writes the `smtp-credentials` K8s Secret into each caller's namespace.
 *
 * Invoked by scripts/provision-smtp-service-accounts (which handles
 * tenant-config loading, port-forward setup, and env export).
 *
 * Design (see commit message of the enclosing PR for the full rationale):
 *   - ONE principal per tenant (`mailer@<email_domain>`) — Stalwart v0.15
 *     enforces MAIL FROM alignment to the authenticated principal's `emails`
 *     array on authenticated submission and rejects adding the same email to
 *     two principals, so each FROM address needed by any caller must live on
 *     this single principal.
 *   - One app password (`smtp`) and one shared K8s Secret `smtp-credentials`
 *     replicated to every caller namespace that needs to submit mail.
 *
 * Stalwart API quirks handled here:
 *   - HTTP 200 on errors; must parse body.error
 *   - OIDC directory mode: use POST /api/principal/deploy (not /api/principal).
 *   - App passwords stored as "$app$<name>$<password>" in secrets[].
 *   - POST /api/reload after changes clears the negative RCPT TO cache.
 */

'use strict';

const { execFileSync } = require('node:child_process');
const crypto = require('node:crypto');

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`[provision-smtp] Missing required env var: ${name}`);
    process.exit(2);
  }
  return v;
}

const STALWART_API_URL = requireEnv('STALWART_API_URL');
const STALWART_ADMIN_PASSWORD = requireEnv('STALWART_ADMIN_PASSWORD');
const EMAIL_DOMAIN = requireEnv('EMAIL_DOMAIN');
const MAIL_HOST = requireEnv('MAIL_HOST');
const TENANT = requireEnv('MT_TENANT');
const NS_STALWART = requireEnv('NS_STALWART');
const NS_ADMIN = requireEnv('NS_ADMIN');
const NS_DOCS = requireEnv('NS_DOCS');
const NS_MATRIX = requireEnv('NS_MATRIX');
const NS_FILES = requireEnv('NS_FILES');
const KUBECONFIG = requireEnv('KUBECONFIG');
const ROTATE = process.env.ROTATE === 'true';

// Callers dial MAIL_HOST (the external mail FQDN, e.g. mail.<tenant-domain>)
// rather than the in-cluster svc FQDN. A per-tenant CoreDNS rewrite (applied
// by deploy-stalwart.sh) makes that name resolve to the Stalwart ClusterIP
// inside the cluster, so TLS verifies against the existing wildcard cert
// while traffic stays in-cluster.
const SMTP_RELAY_HOST = MAIL_HOST;
const SUBMISSION_APP_PORT = '588';
const APP_PASSWORD_NAME = 'smtp';
const SECRET_NAME = 'smtp-credentials';

// Shared service account identity.
const PRINCIPAL_EMAIL = `mailer@${EMAIL_DOMAIN}`;
const PRINCIPAL_DESCRIPTION = 'Shared SMTP submission account for tenant callers (Docs, portals, Synapse, Nextcloud)';

// Every From address any caller uses must live on the principal for Stalwart's
// MAIL FROM alignment check to succeed. Keep this list in sync with caller
// configs (Docs DJANGO_EMAIL_FROM, Nextcloud mail.fromAddress, Synapse
// notif_from, portal mailer/keycloak senders).
const FROM_ADDRESSES = [
  PRINCIPAL_EMAIL,
  `noreply@${EMAIL_DOMAIN}`,
  `calendar@${EMAIL_DOMAIN}`,
];

// Secret is written identically into each caller's namespace.
const CALLER_NAMESPACES = [NS_ADMIN, NS_DOCS, NS_MATRIX, NS_FILES];

function authHeader() {
  return 'Basic ' + Buffer.from(`admin:${STALWART_ADMIN_PASSWORD}`).toString('base64');
}

async function apiFetch(path, init = {}) {
  const res = await fetch(`${STALWART_API_URL}${path}`, {
    ...init,
    headers: { Authorization: authHeader(), ...(init.headers || {}) },
  });
  const text = await res.text();
  if (!text) return { status: res.status, body: null };
  try {
    return { status: res.status, body: JSON.parse(text) };
  } catch {
    throw new Error(`Stalwart API ${path}: non-JSON response (${res.status}): ${text.slice(0, 200)}`);
  }
}

async function getPrincipal(email) {
  const resp = await apiFetch(`/api/principal/${encodeURIComponent(email)}`);
  if (!resp.body || resp.body.error) return null;
  return resp.body.data || resp.body;
}

async function createPrincipal(email, description) {
  const resp = await apiFetch('/api/principal/deploy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      type: 'individual',
      name: email,
      emails: [email],
      description,
      secrets: [],
      roles: ['user'],
    }),
  });
  if (resp.body && resp.body.error === 'fieldAlreadyExists') return { created: false };
  if (resp.body && resp.body.error) {
    throw new Error(`Principal create failed for ${email}: ${resp.body.error} ${resp.body.details || ''}`);
  }
  return { created: true };
}

async function addEmailAlias(email, alias) {
  const resp = await apiFetch(`/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify([{ action: 'addItem', field: 'emails', value: alias }]),
  });
  if (resp.body && resp.body.error === 'fieldAlreadyExists') return { added: false };
  if (resp.body && resp.body.error) {
    throw new Error(`Add email ${alias} failed: ${resp.body.error} ${resp.body.details || ''}`);
  }
  return { added: true };
}

async function removeAppPassword(email, name) {
  const principal = await getPrincipal(email);
  if (!principal) return;
  const secrets = principal.secrets || [];
  const target = secrets.find((s) => s.startsWith(`$app$${name}$`));
  if (!target) return;
  const resp = await apiFetch(`/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify([{ action: 'removeItem', field: 'secrets', value: target }]),
  });
  if (resp.body && resp.body.error) {
    throw new Error(`Remove app password failed: ${resp.body.error}`);
  }
}

async function addAppPassword(email, name, password) {
  const resp = await apiFetch(`/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify([{ action: 'addItem', field: 'secrets', value: `$app$${name}$${password}` }]),
  });
  if (resp.body && resp.body.error) {
    throw new Error(`Add app password failed: ${resp.body.error}`);
  }
}

async function reload() {
  await apiFetch('/api/reload');
}

function generatePassword() {
  return crypto.randomBytes(32).toString('base64').replace(/[=+/]/g, '').slice(0, 24);
}

function kubectl(args, input) {
  const opts = { env: { ...process.env, KUBECONFIG }, stdio: ['pipe', 'pipe', 'inherit'] };
  if (input !== undefined) opts.input = input;
  else opts.stdio = ['ignore', 'pipe', 'inherit'];
  return execFileSync('kubectl', args, opts).toString();
}

function secretExists(namespace, name) {
  try {
    execFileSync('kubectl', ['get', 'secret', name, '-n', namespace, '--no-headers'], {
      env: { ...process.env, KUBECONFIG },
      stdio: ['ignore', 'ignore', 'ignore'],
    });
    return true;
  } catch {
    return false;
  }
}

function writeSecret({ namespace, name, host, port, username, password }) {
  const yaml = kubectl([
    'create', 'secret', 'generic', name,
    '-n', namespace,
    `--from-literal=SMTP_RELAY_HOST=${host}`,
    `--from-literal=SMTP_RELAY_PORT=${port}`,
    `--from-literal=SMTP_RELAY_USERNAME=${username}`,
    `--from-literal=SMTP_RELAY_PASSWORD=${password}`,
    '--dry-run=client', '-o', 'yaml',
  ]);
  kubectl(['apply', '-f', '-'], yaml);
}

async function main() {
  console.log(`[provision-smtp] Tenant ${TENANT} (domain ${EMAIL_DOMAIN}), Stalwart at ${STALWART_API_URL}`);
  let changed = false;

  let principal = await getPrincipal(PRINCIPAL_EMAIL);
  if (!principal) {
    await createPrincipal(PRINCIPAL_EMAIL, PRINCIPAL_DESCRIPTION);
    console.log(`[provision-smtp] Principal created: ${PRINCIPAL_EMAIL}`);
    principal = await getPrincipal(PRINCIPAL_EMAIL);
    changed = true;
  }

  const currentEmails = new Set(principal?.emails || []);
  for (const alias of FROM_ADDRESSES) {
    if (currentEmails.has(alias)) continue;
    const res = await addEmailAlias(PRINCIPAL_EMAIL, alias);
    if (res.added) {
      console.log(`[provision-smtp]   alias added: ${alias}`);
      changed = true;
    }
  }
  // Re-read principal if we added aliases.
  if (changed) principal = await getPrincipal(PRINCIPAL_EMAIL);

  const existingPasswords = (principal?.secrets || [])
    .filter((s) => s.startsWith('$app$'))
    .map((s) => s.split('$')[2]);
  const hasPassword = existingPasswords.includes(APP_PASSWORD_NAME);

  const secretsPresent = CALLER_NAMESPACES.map((ns) => secretExists(ns, SECRET_NAME));
  const allSecretsPresent = secretsPresent.every(Boolean);

  let password = null;
  if (hasPassword && allSecretsPresent && !ROTATE) {
    console.log('[provision-smtp] Credentials already provisioned in every caller namespace; skipping password rotation');
  } else {
    if (hasPassword) {
      const reason = ROTATE ? 'rotation requested' : 'at least one caller namespace missing its Secret';
      console.log(`[provision-smtp] Rotating app password (${reason})`);
      await removeAppPassword(PRINCIPAL_EMAIL, APP_PASSWORD_NAME);
    }
    password = generatePassword();
    await addAppPassword(PRINCIPAL_EMAIL, APP_PASSWORD_NAME, password);
    console.log(`[provision-smtp] App password ${ROTATE || !hasPassword ? 'created' : 'rotated'}`);
    changed = true;
  }

  if (password !== null) {
    // We know the new password; (re)write the Secret in every caller namespace.
    for (const ns of CALLER_NAMESPACES) {
      writeSecret({
        namespace: ns,
        name: SECRET_NAME,
        host: SMTP_RELAY_HOST,
        port: SUBMISSION_APP_PORT,
        username: PRINCIPAL_EMAIL,
        password,
      });
      console.log(`[provision-smtp]   Secret ${SECRET_NAME} written to ${ns}`);
    }
  }

  if (changed) {
    await reload();
    console.log('[provision-smtp] Stalwart config reloaded (RCPT TO cache cleared)');
  } else {
    console.log('[provision-smtp] No changes needed');
  }
  // Exit 0 when something was provisioned/rotated, 2 when nothing changed.
  // The shell wrapper uses this to gate caller rollout restarts so re-running
  // create_env on an existing tenant doesn't bounce pods unnecessarily.
  process.exit(changed ? 0 : 2);
}

main().catch((err) => {
  console.error(`[provision-smtp] ${err.stack || err.message}`);
  process.exit(1);
});
