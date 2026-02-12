/**
 * Stalwart Mail Server API client
 *
 * All operations use admin Basic auth via the admin API.
 * The self-service Bearer token API doesn't work when storage.directory = "oidc"
 * because OIDC creates virtual principals that can't manage internal directory secrets.
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
 * Ensure a user principal exists in Stalwart's internal directory.
 * Creates the principal if it doesn't exist (lazy provisioning).
 */
async function ensureUserExists(email, name) {
  const adminAuth = getAdminAuth();

  const checkResponse = await fetch(`${STALWART_API_URL}/api/principal/${encodeURIComponent(email)}`, {
    headers: { 'Authorization': adminAuth },
  });

  if (checkResponse.ok) {
    return { created: false };
  }

  console.log(`Stalwart: creating principal for ${email}`);
  const createResponse = await fetch(`${STALWART_API_URL}/api/principal`, {
    method: 'POST',
    headers: {
      'Authorization': adminAuth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      type: 'individual',
      name: email,
      emails: [email],
      description: name || '',
      secrets: [],
    }),
  });

  if (createResponse.status === 409) {
    return { created: false };
  }

  if (!createResponse.ok) {
    const error = await createResponse.text();
    throw new Error(`Failed to create Stalwart principal: ${createResponse.status} ${error}`);
  }

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
};
