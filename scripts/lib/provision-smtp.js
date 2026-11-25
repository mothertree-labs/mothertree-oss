#!/usr/bin/env node
/*
 * Provisions the per-tenant shared SMTP service account in Stalwart and
 * writes the `smtp-credentials` K8s Secret into each caller's namespace.
 *
 * Invoked by scripts/provision-smtp-service-accounts (which handles
 * tenant-config loading, port-forward setup, and env export).
 *
 * Design (see commit message of the enclosing PR for the full rationale):
 *   - ONE account per tenant (`mailer@<email_domain>`) — Stalwart enforces
 *     MAIL FROM alignment to the authenticated account's addresses on
 *     authenticated submission and rejects giving the same address to two
 *     accounts, so each FROM address needed by any caller is an alias of this
 *     single account.
 *   - One app password (`smtp`) and one shared K8s Secret `smtp-credentials`
 *     replicated to every caller namespace that needs to submit mail.
 *
 * Stalwart v1 JMAP management API (issue #715; replaced the 0.15 REST API):
 *   - POST <base>/jmap/ as the recovery admin; errors are HTTP 200 with
 *     method-level ["error", ...] or per-id notCreated/notUpdated/notDestroyed.
 *   - Accounts are named by local part + domainId; aliases are a keyed map.
 *   - App password secrets are SERVER-GENERATED and returned once on create;
 *     they are never readable again. So the Secret's stored password is the
 *     only copy, and idempotency is decided by logging in with it.
 *   - ReloadSettings after account/alias changes clears the RCPT TO cache.
 */

'use strict';

const { execFileSync } = require('node:child_process');

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
//
// TODO(security): the admin/account portal nodemailer transports still set
// `tls: { rejectUnauthorized: false }`, which defeats the purpose of the
// CoreDNS rewrite (the whole point is that TLS verifies against the wildcard
// cert from in-cluster). Track and remove those flags in a follow-up PR so
// the portals catch the same cert/hostname regressions this smoke test now
// catches at deploy time.
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

const JMAP_USING = ['urn:ietf:params:jmap:core', 'urn:stalwart:jmap'];
const FETCH_TIMEOUT_MS = 30_000;

function basicAuth(user, password) {
  return 'Basic ' + Buffer.from(`${user}:${password}`).toString('base64');
}

/**
 * Send one JMAP request as the recovery admin and return the method
 * responses keyed by call id. Throws on non-2xx HTTP and on any method-level
 * ["error", {...}] response (mirrors apps/admin-portal/api/stalwart.js).
 */
async function jmap(methodCalls) {
  const res = await fetch(`${STALWART_API_URL}/jmap/`, {
    method: 'POST',
    headers: {
      Authorization: basicAuth('admin', STALWART_ADMIN_PASSWORD),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ using: JMAP_USING, methodCalls }),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  if (!res.ok) {
    throw new Error(`Stalwart JMAP request failed: HTTP ${res.status}`);
  }
  const data = await res.json();
  const results = {};
  for (const [name, args, callId] of data.methodResponses || []) {
    if (name === 'error') {
      const call = methodCalls.find((c) => c[2] === callId);
      throw new Error(`Stalwart ${call ? call[0] : callId} failed: ${args?.type || 'unknown'}${args?.description ? ` - ${args.description}` : ''}`);
    }
    results[callId] = args;
  }
  for (const [method, , callId] of methodCalls) {
    if (!results[callId]) throw new Error(`Stalwart ${method} failed: no response for call "${callId}"`);
  }
  return results;
}

function describeSetError(err) {
  if (!err) return 'unknown';
  const props = Array.isArray(err.properties) && err.properties.length ? ` [${err.properties.join(', ')}]` : '';
  return `${err.type || 'unknown'}${err.description ? ` - ${err.description}` : ''}${props}`;
}

function assertSetOk(label, result) {
  for (const key of ['notCreated', 'notUpdated', 'notDestroyed']) {
    const failures = result?.[key];
    if (failures && Object.keys(failures).length > 0) {
      const [id, err] = Object.entries(failures)[0];
      throw new Error(`${label} failed (${id}): ${describeSetError(err)}`);
    }
  }
}

function localPart(address) {
  return address.slice(0, address.lastIndexOf('@')).toLowerCase();
}

// Domains are created by deploy-stalwart.sh (v1 config plan), never here.
async function getDomainId(domain) {
  const res = await jmap([['x:Domain/query', { filter: { name: domain } }, 'd']]);
  const id = res.d.ids?.[0];
  if (!id) {
    throw new Error(`Stalwart domain "${domain}" is not configured — deploy-stalwart.sh must create it first`);
  }
  return id;
}

async function getAccount(email, domainId) {
  const res = await jmap([
    ['x:Account/query', { filter: { name: localPart(email), domainId } }, 'q'],
    ['x:Account/get', {
      '#ids': { resultOf: 'q', name: 'x:Account/query', path: '/ids' },
      properties: ['name', 'emailAddress', 'aliases', 'description'],
    }, 'g'],
  ]);
  return (res.g.list || []).find((a) => (a.emailAddress || '').toLowerCase() === email.toLowerCase()) || null;
}

async function createAccount(email, domainId, description, aliasLocals) {
  const aliases = {};
  aliasLocals.forEach((name, i) => { aliases[String(i)] = { name, domainId, enable: true }; });
  const res = await jmap([['x:Account/set', {
    create: { n: { '@type': 'User', name: localPart(email), domainId, description, aliases } },
  }, 'c']]);
  const failed = res.c.notCreated?.n;
  if (failed) {
    // primaryKeyViolation = already exists (a concurrent deploy won the race).
    if (failed.type === 'primaryKeyViolation') return { created: false };
    throw new Error(`Account create failed for ${email}: ${describeSetError(failed)}`);
  }
  return { created: true };
}

// Add any alias local parts (on `domainId`) the account is missing. Aliases
// are a map keyed by small integers; new ones take the next free keys.
async function addMissingAliases(account, domainId, aliasLocals) {
  const current = account.aliases || {};
  const have = new Set(Object.values(current)
    .filter((a) => a && a.domainId === domainId)
    .map((a) => String(a.name).toLowerCase()));
  const missing = aliasLocals.filter((n) => !have.has(n));
  if (missing.length === 0) return [];
  const patch = {};
  let key = 0;
  for (const name of missing) {
    while (Object.prototype.hasOwnProperty.call(current, String(key))) key += 1;
    patch[`aliases/${key}`] = { name, domainId, enable: true };
    key += 1;
  }
  const res = await jmap([['x:Account/set', { update: { [account.id]: patch } }, 'u']]);
  assertSetOk(`Alias update for ${account.emailAddress}`, res.u);
  return missing;
}

async function listAppPasswordIds(accountId, name) {
  const res = await jmap([['x:AppPassword/get', { accountId }, 'a']]);
  return (res.a.list || []).filter((p) => p.description === name).map((p) => p.id);
}

// Revoke every app password called `name` (secrets are masked on read, so the
// entries cannot be told apart), then create exactly one. Returns the
// server-generated secret — v1 does not let the client choose it.
async function recreateAppPassword(accountId, name) {
  const ids = await listAppPasswordIds(accountId, name);
  if (ids.length > 0) {
    const res = await jmap([['x:AppPassword/set', { accountId, destroy: ids }, 'r']]);
    assertSetOk('App password revoke', res.r);
  }
  const res = await jmap([['x:AppPassword/set', { accountId, create: { a: { description: name } } }, 'p']]);
  assertSetOk('App password create', res.p);
  const secret = res.p.created?.a?.secret;
  if (!secret) throw new Error('App password create returned no secret');
  return secret;
}

// ONE login attempt with the stored password over HTTP Basic (never retried:
// repeated auth failures from the port-forward source could trip Stalwart's
// auth-failure ban). 200 = it still works, 401/403 = stale; anything else is
// an error, not a reason to rotate.
async function passwordLogsIn(email, password) {
  const res = await fetch(`${STALWART_API_URL}/jmap/session`, {
    headers: { Authorization: basicAuth(email, password) },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  await res.arrayBuffer().catch(() => {});
  if (res.status === 200) return true;
  if (res.status === 401 || res.status === 403) return false;
  throw new Error(`Login check for ${email} returned unexpected HTTP ${res.status}`);
}

async function reload() {
  const res = await jmap([['x:Action/set', { create: { r: { '@type': 'ReloadSettings' } } }, 'r']]);
  assertSetOk('Stalwart ReloadSettings', res.r);
}

function kubectl(args, input) {
  const opts = { env: { ...process.env, KUBECONFIG }, stdio: ['pipe', 'pipe', 'inherit'] };
  if (input !== undefined) opts.input = input;
  else opts.stdio = ['ignore', 'pipe', 'inherit'];
  return execFileSync('kubectl', args, opts).toString();
}

// Read a single key from a Secret as plain text (base64-decoded), or null if
// either the Secret or the key is absent. Any other kubectl failure throws:
// mistaking an API hiccup for "no Secret" would revoke a working app password.
function readSecretField(namespace, name, key) {
  let b64;
  try {
    b64 = execFileSync('kubectl', [
      'get', 'secret', name, '-n', namespace,
      '-o', `jsonpath={.data.${key}}`,
    ], { env: { ...process.env, KUBECONFIG }, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
  } catch (err) {
    const stderr = err.stderr ? err.stderr.toString() : '';
    if (/NotFound|not found/.test(stderr)) return null;
    throw new Error(`kubectl get secret ${namespace}/${name} failed: ${stderr.trim().slice(0, 300) || err.message}`);
  }
  if (!b64) return null;
  return Buffer.from(b64, 'base64').toString('utf8');
}

// ---------------------------------------------------------------------------
// End-to-end SMTP smoke test.
//
// Why: the per-tenant CoreDNS rewrite (deploy-stalwart.sh) and the Stalwart
// principal/listener config are both required for callers to actually submit
// mail. A misconfiguration in either layer surfaces later as flaky e2e
// magic-link tests; we'd rather fail the deploy here. The probe verifies the
// full chain — TCP reach to MAIL_HOST:588 (proves CoreDNS rewrite resolved
// to the in-cluster ClusterIP), SMTP banner + EHLO (proves Stalwart's
// submission listener is up), STARTTLS upgrade with hostname verification
// (proves the wildcard cert is presented and aligns with MAIL_HOST — this
// is the regression that motivated the CoreDNS rewrite in the first place).
//
// We deliberately skip SASL auth: it requires adding nodemailer/python to
// the probe image; the three checks above already catch the cold-start
// races we care about (CoreDNS not propagated, Stalwart listener not ready,
// TLS cert mismatch).
//
// The probe runs from a tenant namespace (NS_ADMIN) so the per-tenant
// CoreDNS rewrite applies — DNS rewrites are scoped by the answering pod's
// search domains.
// ---------------------------------------------------------------------------
// One probe attempt. Returns { ok:true } on success, or
// { ok:false, detail } when the path isn't ready yet. Never throws for a
// not-ready result — the retry loop in runSmtpSmokeTest() owns fatality so
// the deploy tolerates cold-start propagation (CoreDNS rewrite, listener
// bind, cert issuance) instead of hard-failing on the first miss.
function smtpSmokeAttempt() {
  const podName = `smtp-smoke-${process.pid}-${Date.now()}`;
  // SMTP_SMOKE_CA_B64 (set by provision-smtp-service-accounts on a devbox,
  // cluster.edge: local): the base64 PEM of the local CA the tenant certs
  // chain to. Verification stays strict; it only adds that trust anchor.
  const caB64 = process.env.SMTP_SMOKE_CA_B64 || '';
  if (caB64 && !/^[A-Za-z0-9+/=]+$/.test(caB64)) {
    throw new Error('SMTP_SMOKE_CA_B64 is not base64');
  }
  const caSetup = caB64 ? `echo '${caB64}' | base64 -d > /tmp/ca.pem` : '';
  const caFlag = caB64 ? ' -CAfile /tmp/ca.pem' : '';
  const shellScript = `
    apk add --no-cache openssl >/dev/null 2>&1
    ${caSetup}
    printf 'EHLO probe\\nQUIT\\n' | openssl s_client \\
      -connect ${MAIL_HOST}:588${caFlag} \\
      -starttls smtp \\
      -verify_hostname ${MAIL_HOST} \\
      -verify_return_error \\
      -crlf -quiet 2>&1 | head -40
  `;

  let output;
  try {
    output = execFileSync('kubectl', [
      'run', podName,
      '-n', NS_ADMIN,
      '--rm', '-i', '--restart=Never',
      '--image=alpine:3.24.4',
      '--quiet',
      '--command', '--',
      'sh', '-c', shellScript,
    ], {
      env: { ...process.env, KUBECONFIG },
      stdio: ['ignore', 'pipe', 'pipe'],
      // Bounded 60s — pod startup ~5–10s, openssl handshake should complete
      // in <5s when healthy.
      timeout: 60_000,
    }).toString();
  } catch (err) {
    // execFileSync throws on non-zero exit OR on timeout (err.signal === 'SIGTERM').
    // Capture whatever output the openssl pipeline managed to print.
    const captured = (err.stdout ? err.stdout.toString() : '') + (err.stderr ? err.stderr.toString() : '');
    // Best-effort cleanup — the pod is `--rm`, but if execFileSync timed out,
    // kubectl was killed before it could delete the pod.
    try {
      execFileSync('kubectl', ['delete', 'pod', podName, '-n', NS_ADMIN, '--ignore-not-found=true', '--force', '--grace-period=0'], {
        env: { ...process.env, KUBECONFIG },
        stdio: ['ignore', 'ignore', 'ignore'],
        timeout: 15_000,
      });
    } catch { /* ignore cleanup errors */ }
    const timedOut = err.signal === 'SIGTERM' || /ETIMEDOUT/.test(String(err.message || ''));
    return { ok: false, detail: `probe ${timedOut ? 'timed out (60s)' : 'errored'}; output: ${captured.slice(0, 2000).replace(/\s+/g, ' ').trim()}` };
  }

  // With `-quiet`, openssl suppresses the 220 banner and the
  // "Verify return code: 0 (ok)" summary line, but it still emits
  // per-cert `verify return:1` lines as the chain is validated and the
  // post-STARTTLS 250-* EHLO response from the upgraded session. Both
  // present means: cert chain validated against -verify_hostname and
  // Stalwart's submission listener responded to EHLO over TLS.
  // (If -verify_hostname or -verify_return_error had failed, openssl
  // would have exited non-zero before we got here.)
  const checks = [
    { name: 'TLS chain verify (verify return:1)', pattern: /verify return:1/ },
    { name: 'EHLO response (250)', pattern: /\b250[- ]/ },
  ];
  const failed = checks.filter((c) => !c.pattern.test(output));
  if (failed.length > 0) {
    return { ok: false, detail: `missing markers: ${failed.map((c) => c.name).join(', ')}; output: ${output.slice(0, 2000).replace(/\s+/g, ' ').trim()}` };
  }
  return { ok: true };
}

// Cold-start gap #19 (provision layer): poll the SMTP smoke test until the
// submission path (TCP→EHLO→STARTTLS→hostname-verify on MAIL_HOST:588) is
// genuinely usable, or a deadline expires. This is the layer that trips
// first on a fresh cluster (CoreDNS rewrite not yet propagated / listener
// not bound / wildcard cert not issued). One-shot would fail deterministically
// on every on-demand-dev cold-start. Still FATAL on the deadline — converts a
// silent shard-6 magic-link flake into a loud, correctly-attributed failure;
// the gate #19 AUTH assertion (mt_wait_for_stalwart_submission, from
// infra-auth) runs after this and covers the distinct SASL-layer race.
function runSmtpSmokeTest() {
  // Defensive parse: a malformed override must not degrade to a NaN-driven
  // busy loop — fall back to the default when not a positive finite number.
  const numEnv = (name, def) => {
    const v = Number(process.env[name]);
    return Number.isFinite(v) && v > 0 ? v : def;
  };
  const DEADLINE_MS = numEnv('SMTP_SMOKE_DEADLINE_MS', 420_000);
  const RETRY_SLEEP_MS = numEnv('SMTP_SMOKE_RETRY_SLEEP_MS', 15_000);

  console.log(
    `[provision-smtp] SMTP smoke test against ${MAIL_HOST}:588 from ${NS_ADMIN} ` +
    `(deadline ~${Math.round(DEADLINE_MS / 1000)}s — tolerating cold-start propagation)`,
  );

  const sab = new Int32Array(new SharedArrayBuffer(4));
  const deadline = Date.now() + DEADLINE_MS;
  let attempt = 0;
  let last = '(no attempt completed)';
  while (Date.now() < deadline) {
    attempt += 1;
    const r = smtpSmokeAttempt();
    if (r.ok) {
      console.log(`[provision-smtp] SMTP smoke test passed on attempt ${attempt} (TCP + EHLO + STARTTLS + hostname verify)`);
      return;
    }
    last = r.detail;
    console.log(`[provision-smtp]   attempt ${attempt} not ready yet: ${r.detail.slice(0, 200)}`);
    if (Date.now() + RETRY_SLEEP_MS >= deadline) break;
    // Synchronous sleep, no deps: wait on an un-notified SharedArrayBuffer.
    Atomics.wait(sab, 0, 0, RETRY_SLEEP_MS);
  }

  throw new Error(
    `SMTP smoke test for ${MAIL_HOST}:588 never succeeded after ${attempt} attempt(s) (~${Math.round(DEADLINE_MS / 1000)}s).\n` +
    `Likely causes:\n` +
    `  • CoreDNS rewrite has not propagated (mail.<domain> still resolves to the public LB IP, which does not expose 588)\n` +
    `  • Stalwart submission listener is not ready on port 588\n` +
    `  • TLS cert mismatch (wildcard cert not presented or hostname does not align with ${MAIL_HOST})\n` +
    `Last probe result:\n${last}`,
  );
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

function readStoredCredentials(namespace) {
  return {
    namespace,
    host: readSecretField(namespace, SECRET_NAME, 'SMTP_RELAY_HOST'),
    port: readSecretField(namespace, SECRET_NAME, 'SMTP_RELAY_PORT'),
    username: readSecretField(namespace, SECRET_NAME, 'SMTP_RELAY_USERNAME'),
    password: readSecretField(namespace, SECRET_NAME, 'SMTP_RELAY_PASSWORD'),
  };
}

async function main() {
  console.log(`[provision-smtp] Tenant ${TENANT} (domain ${EMAIL_DOMAIN}), Stalwart at ${STALWART_API_URL}`);
  let changed = false;

  // ── Account + From aliases ────────────────────────────────────────────────
  const domainId = await getDomainId(EMAIL_DOMAIN);
  const aliasLocals = FROM_ADDRESSES.filter((a) => a !== PRINCIPAL_EMAIL).map(localPart);

  let account = await getAccount(PRINCIPAL_EMAIL, domainId);
  if (!account) {
    const res = await createAccount(PRINCIPAL_EMAIL, domainId, PRINCIPAL_DESCRIPTION, aliasLocals);
    console.log(res.created
      ? `[provision-smtp] Account created: ${PRINCIPAL_EMAIL}`
      : `[provision-smtp] Account ${PRINCIPAL_EMAIL} appeared concurrently; reusing it`);
    account = await getAccount(PRINCIPAL_EMAIL, domainId);
    if (!account) throw new Error(`Account ${PRINCIPAL_EMAIL} not found right after create`);
    changed = changed || res.created;
  }

  const added = await addMissingAliases(account, domainId, aliasLocals);
  for (const name of added) {
    console.log(`[provision-smtp]   alias added: ${name}@${EMAIL_DOMAIN}`);
    changed = true;
  }

  // ── App password ──────────────────────────────────────────────────────────
  // v1 secrets are server-generated and unreadable after creation, so the
  // Secrets in the caller namespaces hold the only copy. Keep it when an
  // `smtp` app password exists AND the stored password still logs in;
  // otherwise revoke every `smtp` app password and create a fresh one.
  const stored = CALLER_NAMESPACES.map(readStoredCredentials);
  const candidate = (stored.find((s) => s.password) || {}).password || null;

  let password = null;
  let reason = null;
  if (ROTATE) {
    reason = 'rotation requested';
  } else if (!candidate) {
    reason = 'no caller namespace holds a stored password';
  } else if ((await listAppPasswordIds(account.id, APP_PASSWORD_NAME)).length === 0) {
    reason = `no "${APP_PASSWORD_NAME}" app password exists in Stalwart`;
  } else if (!(await passwordLogsIn(PRINCIPAL_EMAIL, candidate))) {
    reason = 'the stored password no longer logs in';
  } else {
    password = candidate;
    console.log('[provision-smtp] Stored app password still logs in; keeping it');
  }

  if (password === null) {
    console.log(`[provision-smtp] Creating a new app password (${reason})`);
    password = await recreateAppPassword(account.id, APP_PASSWORD_NAME);
    changed = true;
  }

  // ── Secrets ───────────────────────────────────────────────────────────────
  // Rewrite every caller Secret that is missing or differs from the desired
  // values (new password, host drift such as svc FQDN → MAIL_HOST, port or
  // username drift). Untouched Secrets keep the conditional-restart invariant.
  for (const s of stored) {
    const upToDate = s.host === SMTP_RELAY_HOST
      && s.port === SUBMISSION_APP_PORT
      && s.username === PRINCIPAL_EMAIL
      && s.password === password;
    if (upToDate) continue;
    writeSecret({
      namespace: s.namespace,
      name: SECRET_NAME,
      host: SMTP_RELAY_HOST,
      port: SUBMISSION_APP_PORT,
      username: PRINCIPAL_EMAIL,
      password,
    });
    console.log(`[provision-smtp]   Secret ${SECRET_NAME} ${s.password === null ? 'written to' : 'updated in'} ${s.namespace}`);
    changed = true;
  }

  if (changed) {
    await reload();
    console.log('[provision-smtp] Stalwart settings reloaded (RCPT TO cache cleared)');
  } else {
    console.log('[provision-smtp] No changes needed');
  }

  // Verify the full SMTP submission path end-to-end before declaring success.
  // Runs on every invocation (changed AND unchanged paths) — the unchanged
  // path still needs verification because nothing else in the deploy proves
  // the listener, cert, and DNS rewrite all line up on a fresh provision.
  // Throws on failure; the outer .catch reports it and exits 1.
  runSmtpSmokeTest();

  // Exit 0 when something was provisioned/rotated, 2 when nothing changed.
  // The shell wrapper uses this to gate caller rollout restarts so re-running
  // create_env on an existing tenant doesn't bounce pods unnecessarily.
  process.exit(changed ? 0 : 2);
}

main().catch((err) => {
  console.error(`[provision-smtp] ${err.stack || err.message}`);
  process.exit(1);
});
