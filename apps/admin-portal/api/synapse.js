/**
 * Synapse Matrix Server API client
 *
 * Creates Matrix user accounts via the Synapse shared-secret registration API.
 * Users authenticate via OIDC (passkeys), so the password set here is random
 * and never used directly. The goal is to ensure the Matrix identity exists
 * before the user's first login, so other users can message them immediately.
 */

const crypto = require('crypto');

const SYNAPSE_ADMIN_URL = process.env.SYNAPSE_ADMIN_URL;
const SYNAPSE_SHARED_SECRET = process.env.SYNAPSE_SHARED_SECRET;
const MATRIX_DOMAIN = process.env.MATRIX_DOMAIN;

// Timeout for Synapse API requests. Guards against indefinitely hung
// connections when the service is unreachable or slow.
const FETCH_TIMEOUT_MS = parseInt(process.env.SYNAPSE_FETCH_TIMEOUT_MS, 10) || 30_000;

function fetchWithTimeout(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
}

/**
 * Ensure a Matrix user exists on Synapse for the given email address.
 *
 * Derives the localpart from the email prefix (e.g., "alice" from "alice@tenant.com"),
 * then registers the user via the Synapse shared-secret registration endpoint.
 * If the user already exists, this is a no-op.
 *
 * @param {string} email - The user's tenant email address
 * @param {string} displayName - The user's display name
 * @returns {Promise<{created: boolean, userId: string}>}
 */
async function ensureMatrixUser(email, displayName) {
  if (!SYNAPSE_ADMIN_URL || !SYNAPSE_SHARED_SECRET || !MATRIX_DOMAIN) {
    throw new Error('Synapse API not configured (SYNAPSE_ADMIN_URL, SYNAPSE_SHARED_SECRET, or MATRIX_DOMAIN missing)');
  }

  // Derive localpart from email prefix
  const localpart = email.split('@')[0].toLowerCase();
  const matrixUserId = `@${localpart}:${MATRIX_DOMAIN}`;

  // Generate a random password (user will authenticate via OIDC, not this password)
  const randomPassword = crypto.randomBytes(32).toString('base64url');

  // Step 1: Get a registration nonce from Synapse
  const nonceResponse = await fetchWithTimeout(`${SYNAPSE_ADMIN_URL}/_synapse/admin/v1/register`, {
    method: 'GET',
  });

  if (!nonceResponse.ok) {
    const error = await nonceResponse.text();
    throw new Error(`Failed to get Synapse registration nonce: ${nonceResponse.status} ${error}`);
  }

  const { nonce } = await nonceResponse.json();

  // Step 2: Compute HMAC-SHA1: nonce\0username\0password\0notadmin
  const hmacMessage = `${nonce}\x00${localpart}\x00${randomPassword}\x00notadmin`;
  const mac = crypto.createHmac('sha1', SYNAPSE_SHARED_SECRET)
    .update(hmacMessage)
    .digest('hex');

  // Step 3: Register the user
  const registerResponse = await fetchWithTimeout(`${SYNAPSE_ADMIN_URL}/_synapse/admin/v1/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      nonce,
      username: localpart,
      password: randomPassword,
      admin: false,
      mac,
      displayname: displayName,
    }),
  });

  if (registerResponse.status === 400) {
    const errorBody = await registerResponse.json().catch(() => ({}));
    // "User ID already taken" means the user exists — not an error
    if (errorBody.errcode === 'M_USER_IN_USE') {
      console.log(`Synapse: user ${matrixUserId} already exists`);
      return { created: false, userId: matrixUserId };
    }
    throw new Error(`Failed to register Synapse user: ${JSON.stringify(errorBody)}`);
  }

  if (!registerResponse.ok) {
    const error = await registerResponse.text();
    throw new Error(`Failed to register Synapse user: ${registerResponse.status} ${error}`);
  }

  console.log(`Synapse: user ${matrixUserId} created with display name "${displayName}"`);
  return { created: true, userId: matrixUserId };
}

module.exports = {
  ensureMatrixUser,
};
