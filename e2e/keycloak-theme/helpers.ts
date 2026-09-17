import {
  expect,
  request as playwrightRequest,
  type APIRequestContext,
  type APIResponse,
  type Page,
} from '@playwright/test';

/**
 * Shared plumbing for the hermetic Keycloak theme specs. Run them via
 * ci/scripts/keycloak-theme-test.sh, which boots the pinned image and sets the env.
 */

export function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} must be set — run this suite via ci/scripts/keycloak-theme-test.sh`);
  }
  return value;
}

export const KC_URL = requiredEnv('KC_THEME_TEST_URL').replace(/\/$/, '');
const ADMIN_USER = requiredEnv('KC_THEME_TEST_ADMIN_USER');
const ADMIN_PASSWORD = requiredEnv('KC_THEME_TEST_ADMIN_PASSWORD');

// Never loaded: specs only watch for Keycloak's redirect to it (.invalid never
// resolves, and page.route() does not see the redirect leg of a POST).
export const REDIRECT_URI = 'https://app.theme-test.invalid/callback';

export async function ensureOk(res: APIResponse, what: string): Promise<APIResponse> {
  if (!res.ok()) {
    throw new Error(`${what}: HTTP ${res.status()} ${await res.text()}`);
  }
  return res;
}

/** Admin REST client. Master-realm admin tokens live 60s, so mint one per phase. */
export async function adminApi(): Promise<APIRequestContext> {
  const anon = await playwrightRequest.newContext({ baseURL: KC_URL });
  const tokenRes = await ensureOk(
    await anon.post('/realms/master/protocol/openid-connect/token', {
      form: {
        grant_type: 'password',
        client_id: 'admin-cli',
        username: ADMIN_USER,
        password: ADMIN_PASSWORD,
      },
    }),
    'admin token',
  );
  const { access_token: token } = await tokenRes.json();
  await anon.dispose();
  return playwrightRequest.newContext({
    baseURL: KC_URL,
    extraHTTPHeaders: { Authorization: `Bearer ${token}` },
  });
}

/** (Re)create a realm on the platform login theme. Idempotent against a long-lived local Keycloak. */
export async function recreateRealm(api: APIRequestContext, realm: string, settings: Record<string, unknown>): Promise<void> {
  if ((await api.get(`/admin/realms/${realm}`)).ok()) {
    await ensureOk(await api.delete(`/admin/realms/${realm}`), `delete stale realm ${realm}`);
  }
  await ensureOk(
    await api.post('/admin/realms', { data: { realm, enabled: true, loginTheme: 'platform', ...settings } }),
    `create realm ${realm}`,
  );
}

/** Create a user and return its id (from the Location header). */
export async function createUser(api: APIRequestContext, realm: string, user: Record<string, unknown>): Promise<string> {
  const res = await ensureOk(await api.post(`/admin/realms/${realm}/users`, { data: user }), 'create user');
  const userId = res.headers()['location']?.split('/').pop();
  if (!userId) {
    throw new Error('create user: Keycloak returned no Location header');
  }
  return userId;
}

export function authUrl(realm: string, clientId: string): string {
  return `${KC_URL}/realms/${realm}/protocol/openid-connect/auth?${new URLSearchParams({
    client_id: clientId,
    redirect_uri: REDIRECT_URI,
    response_type: 'code',
    scope: 'openid',
  })}`;
}

/** login.ftl keeps the password form behind the admin-login toggle. */
export async function passwordLogin(page: Page, username: string, password: string): Promise<void> {
  await page.locator('#show-admin-login').click();
  await page.locator('#username').fill(username);
  await page.locator('#password').fill(password);
  await page.locator('#admin-login-form button[type="submit"]').click();
}

/** Record navigations to REDIRECT_URI; returns a getter for the last one seen. */
export function watchClientRedirect(page: Page): () => URL | undefined {
  let redirect: URL | undefined;
  page.on('request', (req) => {
    if (req.isNavigationRequest() && req.url().startsWith(REDIRECT_URI)) {
      redirect = new URL(req.url());
    }
  });
  return () => redirect;
}

export async function expectClientRedirectWithCode(getRedirect: () => URL | undefined, what: string): Promise<void> {
  await expect.poll(() => getRedirect() !== undefined, { message: what, timeout: 20_000 }).toBe(true);
  expect(getRedirect()?.searchParams.get('code'), `${what}: redirect should carry an authorization code`).toBeTruthy();
}
