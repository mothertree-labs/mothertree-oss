/**
 * Stalwart Mail Server API client
 *
 * All operations use admin Basic auth via the admin API.
 */

const STALWART_API_URL = process.env.STALWART_API_URL;
const STALWART_ADMIN_PASSWORD = process.env.STALWART_ADMIN_PASSWORD;

function getAdminAuth() {
  if (!STALWART_API_URL || !STALWART_ADMIN_PASSWORD) {
    throw new Error('Stalwart API not configured (STALWART_API_URL or STALWART_ADMIN_PASSWORD missing)');
  }
  return 'Basic ' + Buffer.from(`admin:${STALWART_ADMIN_PASSWORD}`).toString('base64');
}

/**
 * Reload Stalwart configuration and clear directory caches.
 * Called after principal changes to ensure RCPT TO reflects current state.
 */
async function reloadConfig() {
  const adminAuth = getAdminAuth();
  const response = await fetch(`${STALWART_API_URL}/api/reload`, {
    headers: { 'Authorization': adminAuth },
  });
  if (!response.ok) {
    console.warn(`Stalwart: config reload returned ${response.status}`);
  }
}

/**
 * Ensure a user principal exists in Stalwart.
 * Uses /api/principal/deploy which works with both OIDC and internal directories
 * (unlike POST /api/principal which returns "unsupported" with OIDC directory).
 */
async function ensureUserExists(email, name, quotaBytes) {
  const adminAuth = getAdminAuth();

  const checkResponse = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

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
  const createResponse = await fetch(`${STALWART_API_URL}/api/principal/deploy`, {
    method: 'POST',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (createResponse.status === 409) {
    return { created: false };
  }

  if (!createResponse.ok) {
    // Don't fail - principal might exist via OIDC directory
    console.log(`Stalwart: principal may exist via directory (status ${createResponse.status})`);
  }

  const responseData = await createResponse.json();
  // Don't throw - user might exist via directory even if deploy fails
  if (responseData.error && responseData.error !== 'fieldAlreadyExists') {
    console.log(`Stalwart: principal may exist via directory: ${responseData.error}`);
  }

  // Clear directory cache so RCPT TO picks up the new principal immediately
  await reloadConfig();

  console.log(`Stalwart: principal ${email} created`);
  return { created: true };
}

/**
 * List app passwords for a user by reading their principal's secrets.
 * App passwords are stored as "$app$<name>$<password>" in the secrets array.
 */
async function listAppPasswords(email) {
  const adminAuth = getAdminAuth();

  const response = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
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

  const response = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
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
  const getResponse = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
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

  const response = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
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
  listAppPasswords,
  createAppPassword,
  revokeAppPassword,
  setUserCrypto,
};

/**
 * Enable encryption-at-rest for a user by setting their PGP public key.
 * Uses the admin API with master-user auth pattern: user@domain%master
 */
async function setUserCrypto(email, pgpPublicKey, algo = 'Aes256', allowSpamTraining = true) {
  const adminAuth = getAdminAuth();

  // First, get the current principal to check if it exists
  const getResponse = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (!getResponse.ok) {
    const error = await getResponse.text();
    throw new Error(`Failed to get principal: ${getResponse.status} ${error}`);
  }

  const data = await getResponse.json();
  if (data.error === 'notFound') {
    throw new Error(`Principal not found: ${data.error}`);
  }
  // Note: Some responses include error key even for existing principals - ignore those

  // Set crypto via account API using master-user authentication
  // Format: user@domain%master:admin_password
  const masterAuth = Buffer.from(`${email}%master:${STALWART_ADMIN_PASSWORD}`).toString('base64');

  const cryptoBody = {
    type: 'pGP',
    algo: algo,
    certs: pgpPublicKey,
    allow_spam_training: allowSpamTraining,
  };

  const cryptoResponse = await fetch(`${STALWART_API_URL}/api/account/crypto`, {
    method: 'POST',
    headers: {
      'Authorization': 'Basic ' + masterAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(cryptoBody),
  });

  if (!cryptoResponse.ok) {
    const error = await cryptoResponse.text();
    throw new Error(`Failed to set crypto: ${cryptoResponse.status} ${error}`);
  }

  const result = await cryptoResponse.json();
  return result;
}
