/**
 * Keycloak admin API access for tests that need to act on a user the product
 * created, rather than on a pre-provisioned fixture user.
 *
 * Uses the same `admin-portal` service account and per-pool realm that
 * ci-create-test-users.sh uses; ci-resolve-tenant.sh exports E2E_KC_REALM and
 * E2E_KC_CLIENT_SECRET into every shard. Locally they are usually absent, so
 * callers skip instead of failing.
 */

import { urls } from './urls';

const CLIENT_ID = 'admin-portal';

/**
 * Every account these helpers mutate or delete must live in the reserved test
 * domain. The realm and base domain come from the environment, so without this
 * a stray E2E_BASE_DOMAIN would point the admin-portal service account — and
 * deleteUser — at a real tenant's realm.
 */
const TEST_GUEST_DOMAIN = '@external-test.example';

function assertTestGuest(user: KeycloakUser): void {
  const email = (user.email || user.username || '').toLowerCase();
  if (!email.endsWith(TEST_GUEST_DOMAIN)) {
    throw new Error(
      `Refusing to modify Keycloak user ${user.id}: "${email}" is not a ${TEST_GUEST_DOMAIN} ` +
        'test guest. These helpers may only touch accounts the tests themselves generated.',
    );
  }
}

function realm(): string {
  return process.env.E2E_KC_REALM || '';
}

export function isKeycloakAdminConfigured(): boolean {
  return Boolean(realm() && process.env.E2E_KC_CLIENT_SECRET);
}

async function adminToken(): Promise<string> {
  const resp = await fetch(`${urls.keycloak}/realms/${realm()}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: process.env.E2E_KC_CLIENT_SECRET || '',
    }),
  });
  if (!resp.ok) {
    throw new Error(
      `Keycloak token request failed: HTTP ${resp.status}. ` +
        `Realm "${realm()}", client "${CLIENT_ID}" — check E2E_KC_CLIENT_SECRET.`,
    );
  }
  return (await resp.json()).access_token;
}

async function adminApi(
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  const token = await adminToken();
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
    ...((init.headers as Record<string, string>) || {}),
  };
  if (init.body) {
    headers['Content-Type'] = 'application/json';
  }
  return fetch(`${urls.keycloak}/admin/realms/${realm()}${path}`, { ...init, headers });
}

export interface KeycloakUser {
  id: string;
  username: string;
  email?: string;
  requiredActions?: string[];
}

/** The user with this exact email, or null while none exists yet. */
export async function findUserByEmail(email: string): Promise<KeycloakUser | null> {
  const resp = await adminApi(`/users?email=${encodeURIComponent(email)}&exact=true`);
  if (!resp.ok) {
    throw new Error(`Keycloak user lookup failed for ${email}: HTTP ${resp.status}`);
  }
  const users = (await resp.json()) as KeycloakUser[];
  return users.length > 0 ? users[0] : null;
}

/** Poll until the user exists, e.g. while guest_bridge provisions a guest. */
export async function waitForUserByEmail(
  email: string,
  timeoutMs = 60_000,
): Promise<KeycloakUser> {
  const deadline = Date.now() + timeoutMs;
  let lastError = '';
  while (Date.now() < deadline) {
    try {
      const user = await findUserByEmail(email);
      if (user) return user;
    } catch (err) {
      lastError = (err as Error).message;
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(
    `Keycloak user ${email} never appeared within ${timeoutMs}ms.${lastError ? ` Last error: ${lastError}` : ''} ` +
      'A guest is provisioned by the Nextcloud guest_bridge app calling the account portal ' +
      '/api/provision-guest, so check guest_bridge config (api_url/api_key) and the account portal logs.',
  );
}

/**
 * Put a provisioned guest into the state they reach after completing setup:
 * named, verified, no pending required actions, and able to sign in with a
 * password. Passkey registration itself is covered by e2e/keycloak-theme/.
 */
export async function completeGuestSetup(
  user: KeycloakUser,
  { firstName, lastName, password }: { firstName: string; lastName: string; password: string },
): Promise<void> {
  assertTestGuest(user);
  const userId = user.id;
  const update = await adminApi(`/users/${userId}`, {
    method: 'PUT',
    body: JSON.stringify({
      firstName,
      lastName,
      emailVerified: true,
      enabled: true,
      requiredActions: [],
    }),
  });
  if (!update.ok) {
    throw new Error(`Failed to clear required actions for ${userId}: HTTP ${update.status}`);
  }

  const credential = await adminApi(`/users/${userId}/reset-password`, {
    method: 'PUT',
    body: JSON.stringify({ type: 'password', value: password, temporary: false }),
  });
  if (!credential.ok) {
    throw new Error(`Failed to set a password for ${userId}: HTTP ${credential.status}`);
  }
}

/**
 * Cleanup. The HTTP call is best-effort, but the test-domain guard is not: being
 * asked to delete an account outside the reserved domain means the test lost track
 * of the user it created, which should fail loudly rather than proceed.
 */
export async function deleteUser(user: KeycloakUser): Promise<void> {
  assertTestGuest(user);
  await adminApi(`/users/${user.id}`, { method: 'DELETE' }).catch(() => undefined);
}
