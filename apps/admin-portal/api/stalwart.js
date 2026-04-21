/**
 * Stalwart Mail Server API client
 *
 * All operations use admin Basic auth via the admin API.
 */

const STALWART_API_URL = process.env.STALWART_API_URL;
const STALWART_ADMIN_PASSWORD = process.env.STALWART_ADMIN_PASSWORD;

// Timeout for a single Stalwart API request. ensureUserExists() now runs in
// the invite request's critical path (principal must exist before Keycloak's
// RCPT TO validates), so a hung request blocks the HTTP response and trips
// e2e's 15s waitForResponse. 8s per attempt + 500ms backoff + retry caps
// the worst case at ~16.5s while keeping the typical case unchanged (<1s).
// Reproduced: 30 concurrent invites saturated Stalwart during a pipeline's
// e2e run; 17/30 /api/principal/deploy calls never returned within 120s.
const FETCH_TIMEOUT_MS = parseInt(process.env.STALWART_FETCH_TIMEOUT_MS, 10) || 8_000;

function fetchWithTimeout(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
}

// Detect the error thrown by AbortSignal.timeout(N) — either AbortError/
// TimeoutError (name) or a string we can match.
function isTimeoutError(err) {
  if (!err) return false;
  const name = err.name || '';
  const msg = err.message || '';
  return name === 'TimeoutError' || name === 'AbortError' || /aborted due to timeout/i.test(msg);
}

// Run fn(), and if it rejects with an AbortSignal.timeout, wait `delayMs` and
// retry once. On the second failure, throw. Keeps the retry local to the
// call sites that need it so most callers stay simple.
async function withTimeoutRetry(label, fn, delayMs = 500) {
  try {
    return await fn();
  } catch (err) {
    if (!isTimeoutError(err)) throw err;
    console.warn(`Stalwart: ${label} timed out after ${FETCH_TIMEOUT_MS}ms, retrying once`);
    await new Promise((r) => setTimeout(r, delayMs));
    return fn();
  }
}

function getAdminAuth() {
  if (!STALWART_API_URL || !STALWART_ADMIN_PASSWORD) {
    throw new Error('Stalwart API not configured (STALWART_API_URL or STALWART_ADMIN_PASSWORD missing)');
  }
  return 'Basic ' + Buffer.from(`admin:${STALWART_ADMIN_PASSWORD}`).toString('base64');
}

/**
 * Reload Stalwart configuration and clear directory caches.
 * Called after principal changes to ensure RCPT TO reflects current state.
 *
 * Fire-and-forget: returns a promise but callers do NOT await it in the
 * request's critical path. Under concurrent invite load the reload endpoint
 * is a serialization point — awaiting it per-invite was compounding the
 * Stalwart contention that caused e2e's "aborted due to timeout" failures.
 * The negative RCPT cache has a short TTL, and e2e's IMAP polling already
 * buffers past that.
 */
function reloadConfig() {
  const adminAuth = getAdminAuth();
  return fetchWithTimeout(`${STALWART_API_URL}/api/reload`, {
    headers: { 'Authorization': adminAuth },
  })
    .then((response) => {
      if (!response.ok) {
        console.warn(`Stalwart: config reload returned ${response.status}`);
      }
    })
    .catch((err) => {
      console.warn(`Stalwart: config reload failed (non-fatal): ${err.message}`);
    });
}

/**
 * Ensure a user principal exists in Stalwart.
 * Uses /api/principal/deploy which works with both OIDC and internal directories
 * (unlike POST /api/principal which returns "unsupported" with OIDC directory).
 */
async function ensureUserExists(email, name, quotaBytes) {
  const adminAuth = getAdminAuth();

  const checkResponse = await withTimeoutRetry(
    `GET /api/principal/${email}`,
    () => fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
      headers: { 'Authorization': adminAuth },
    }),
  );

  // Stalwart returns HTTP 200 for all responses, including errors.
  // Must parse the body to check for {"error":"notFound"}.
  if (checkResponse.ok) {
    const checkData = await checkResponse.json();
    if (!checkData.error) {
      return { created: false };
    }
  }

  console.log(`Stalwart: creating principal for ${email}`);
  const body = {
    type: 'individual',
    name: email,
    emails: [email],
    description: name || '',
    secrets: [],
    roles: ['user'],
  };
  if (quotaBytes) {
    body.quota = quotaBytes;
  }
  const createResponse = await withTimeoutRetry(
    `POST /api/principal/deploy (${email})`,
    () => fetchWithTimeout(`${STALWART_API_URL}/api/principal/deploy`, {
      method: 'POST',
      headers: {
        'Authorization': adminAuth,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    }),
  );

  if (createResponse.status === 409) {
    return { created: false };
  }

  if (!createResponse.ok) {
    const error = await createResponse.text();
    throw new Error(`Failed to create Stalwart principal: ${createResponse.status} ${error}`);
  }

  const responseData = await createResponse.json();
  if (responseData.error === 'fieldAlreadyExists') {
    return { created: false };
  }
  if (responseData.error) {
    throw new Error(`Stalwart principal creation failed: ${responseData.error} - ${responseData.details || 'no details'}`);
  }

  // Verify the principal was created with the correct roles.
  // The deploy endpoint may silently drop the roles field in some Stalwart
  // versions, leaving the user unable to receive inbound email (bounces with
  // "security.unauthorized" / "This account is not authorized to receive email").
  await ensureRoles(email);

  // Clear directory cache so RCPT TO picks up the new principal immediately
  await reloadConfig();

  console.log(`Stalwart: principal ${email} created`);
  return { created: true };
}

/**
 * Verify a principal has roles: ['user'] and PATCH if missing.
 * Without the 'user' role, Stalwart rejects inbound email delivery with
 * "security.unauthorized" / "This account is not authorized to receive email".
 * See: https://github.com/mothertree-labs/mothertree-oss/issues/189
 */
async function ensureRoles(email) {
  const adminAuth = getAdminAuth();

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!response.ok) return;

  const data = await response.json();
  if (data.error) return;

  const roles = data.data?.roles || [];
  if (roles.includes('user')) return;

  console.log(`Stalwart: principal ${email} missing 'user' role, patching...`);
  const patchResponse = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([{
      action: 'set',
      field: 'roles',
      value: ['user'],
    }]),
  });

  if (!patchResponse.ok) {
    console.warn(`Stalwart: failed to patch roles for ${email}: ${patchResponse.status}`);
  }
}

/**
 * Get the quota for a user principal.
 * Returns quota in bytes (0 = unlimited).
 */
async function getUserQuota(email) {
  const adminAuth = getAdminAuth();

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!response.ok) {
    if (response.status === 404) return { quota: 0 };
    const error = await response.text();
    throw new Error(`Failed to get principal: ${response.status} ${error}`);
  }

  const data = await response.json();
  return { quota: data.data?.quota || 0 };
}

/**
 * Set the quota for a user principal.
 * quotaBytes = 0 means unlimited.
 */
async function setUserQuota(email, quotaBytes) {
  const adminAuth = getAdminAuth();

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([{
      action: 'set',
      field: 'quota',
      value: quotaBytes,
    }]),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to set quota: ${response.status} ${error}`);
  }

  return { success: true };
}

/**
 * Backfill quotas for all existing users that have no quota set (quota === 0).
 * Skips the admin principal.
 */
async function backfillQuotas(defaultQuotaBytes) {
  const adminAuth = getAdminAuth();

  const listResponse = await fetchWithTimeout(`${STALWART_API_URL}/api/principal?types=individual&limit=0`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!listResponse.ok) {
    const error = await listResponse.text();
    throw new Error(`Failed to list principals: ${listResponse.status} ${error}`);
  }

  const listData = await listResponse.json();
  const items = listData.data?.items || [];

  let updated = 0;
  let skipped = 0;
  for (const item of items) {
    const principalName = typeof item === 'string' ? item : item.name;
    if (!principalName || principalName === 'admin') {
      skipped++;
      continue;
    }

    // If the list response includes quota info, use it directly
    if (typeof item === 'object' && item.quota && item.quota > 0) {
      skipped++;
      continue;
    }

    // Otherwise fetch the full principal to check
    if (typeof item === 'string') {
      const principal = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(principalName)}`, {
        headers: { 'Authorization': adminAuth },
      });

      if (!principal.ok) {
        skipped++;
        continue;
      }

      const data = await principal.json();
      if (data.data?.quota && data.data.quota > 0) {
        skipped++;
        continue;
      }
    }

    const patchResponse = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(principalName)}`, {
      method: 'PATCH',
      headers: {
        'Authorization': adminAuth,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify([{
        action: 'set',
        field: 'quota',
        value: defaultQuotaBytes,
      }]),
    });

    if (patchResponse.ok) {
      updated++;
    } else {
      skipped++;
    }
  }

  console.log(`Stalwart: backfilled quotas for ${updated} users (${skipped} skipped)`);
  return { updated, skipped };
}

/**
 * List app passwords for a user by reading their principal's secrets.
 * App passwords are stored as "$app$<name>$<password>" in the secrets array.
 */
async function listAppPasswords(email) {
  const adminAuth = getAdminAuth();

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!response.ok) {
    if (response.status === 404) return [];
    const error = await response.text();
    throw new Error(`Failed to get principal: ${response.status} ${error}`);
  }

  const data = await response.json();
  const secrets = data.data?.secrets || [];

  return secrets
    .filter(s => s.startsWith('$app$'))
    .map(s => {
      // Format: $app$<name>$<password>
      const parts = s.split('$');
      // parts: ['', 'app', '<name>', '<password>']
      return { name: parts[2] };
    });
}

/**
 * Create an app password for a user via admin PATCH API.
 * Stored as "$app$<name>$<password>" in the principal's secrets.
 */
async function createAppPassword(email, deviceName, password) {
  const adminAuth = getAdminAuth();

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([{
      action: 'addItem',
      field: 'secrets',
      value: `$app$${deviceName}$${password}`,
    }]),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create app password: ${response.status} ${error}`);
  }

  return { success: true };
}

/**
 * Revoke an app password by name.
 * Looks up the full secret value from the principal, then removes it.
 */
async function revokeAppPassword(email, passwordName) {
  const adminAuth = getAdminAuth();

  // Get current secrets to find the full value
  const getResponse = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!getResponse.ok) {
    const error = await getResponse.text();
    throw new Error(`Failed to get principal: ${getResponse.status} ${error}`);
  }

  const data = await getResponse.json();
  const secrets = data.data?.secrets || [];
  const target = secrets.find(s => s.startsWith(`$app$${passwordName}$`));

  if (!target) {
    throw new Error(`App password "${passwordName}" not found`);
  }

  const response = await fetchWithTimeout(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    method: 'PATCH',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([{
      action: 'removeItem',
      field: 'secrets',
      value: target,
    }]),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to revoke app password: ${response.status} ${error}`);
  }

  return { success: true };
}

module.exports = {
  ensureUserExists,
  ensureRoles,
  listAppPasswords,
  createAppPassword,
  revokeAppPassword,
  getUserQuota,
  setUserQuota,
  backfillQuotas,
};
