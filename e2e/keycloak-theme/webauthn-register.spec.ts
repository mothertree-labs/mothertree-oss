import { randomUUID } from 'crypto';
import {
  test,
  expect,
  request as playwrightRequest,
  type APIRequestContext,
  type APIResponse,
} from '@playwright/test';

/**
 * The passkey registration page (apps/themes/platform/login/webauthn-register.ftl)
 * against the real Keycloak image it ships with.
 *
 * Regression guard for the 2026-09 production break of guest and invited-user
 * onboarding: clicking "Register Passkey" threw
 *   Uncaught ReferenceError: base64url is not defined
 * because the template loaded base64url (and jquery) from
 * ${url.resourcesCommonPath}/node_modules/, a path no Keycloak 26 image ships.
 * The dev-cluster e2e suite could not see it: onboarding-full-flow.spec.ts
 * re-implements the WebAuthn ceremony in page.evaluate() and submits the form
 * itself, and webauthn-register-magic-link-option.spec.ts never clicks the button.
 *
 * This test runs the page's OWN script — it clicks the real button and lets a
 * CDP virtual authenticator answer navigator.credentials.create() — and fails on
 * any uncaught page error, any Keycloak resource that fails to load, or if
 * Keycloak does not end up storing a passkey for the user.
 *
 * Run via ci/scripts/keycloak-theme-test.sh, which boots the pinned image.
 */

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} must be set — run this suite via ci/scripts/keycloak-theme-test.sh`);
  }
  return value;
}

const KC_URL = requiredEnv('KC_THEME_TEST_URL').replace(/\/$/, '');
const ADMIN_USER = requiredEnv('KC_THEME_TEST_ADMIN_USER');
const ADMIN_PASSWORD = requiredEnv('KC_THEME_TEST_ADMIN_PASSWORD');

const REALM = 'theme-test';
const CLIENT_ID = 'theme-test';
// Never loaded: the test only watches for Keycloak's redirect to it (.invalid
// never resolves, and page.route() does not see the redirect leg of a POST).
const REDIRECT_URI = 'https://app.theme-test.invalid/callback';
const USER = { email: 'guest@theme-test.invalid', password: randomUUID() };

async function ensureOk(res: APIResponse, what: string): Promise<APIResponse> {
  if (!res.ok()) {
    throw new Error(`${what}: HTTP ${res.status()} ${await res.text()}`);
  }
  return res;
}

/** Admin REST client. Master-realm admin tokens live 60s, so mint one per phase. */
async function adminApi(): Promise<APIRequestContext> {
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

/**
 * Realm on the platform login theme with the same passwordless policy
 * docs/import-keycloak-realm.sh applies to tenant realms, and a user who must
 * register a passkey on next login. Returns the user id.
 */
async function seedRealm(api: APIRequestContext): Promise<string> {
  // Idempotent against a long-lived local Keycloak.
  if ((await api.get(`/admin/realms/${REALM}`)).ok()) {
    await ensureOk(await api.delete(`/admin/realms/${REALM}`), 'delete stale realm');
  }

  await ensureOk(
    await api.post('/admin/realms', {
      data: {
        realm: REALM,
        enabled: true,
        displayName: 'Theme Test',
        loginTheme: 'platform',
        webAuthnPolicyPasswordlessRpEntityName: 'Theme Test',
        webAuthnPolicyPasswordlessSignatureAlgorithms: ['ES256', 'RS256'],
        webAuthnPolicyPasswordlessRpId: new URL(KC_URL).hostname,
        webAuthnPolicyPasswordlessAttestationConveyancePreference: 'not specified',
        webAuthnPolicyPasswordlessAuthenticatorAttachment: 'not specified',
        webAuthnPolicyPasswordlessRequireResidentKey: 'Yes',
        webAuthnPolicyPasswordlessUserVerificationRequirement: 'required',
        webAuthnPolicyPasswordlessCreateTimeout: 0,
        webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister: false,
      },
    }),
    'create realm',
  );

  const raPath = `/admin/realms/${REALM}/authentication/required-actions/webauthn-register-passwordless`;
  const requiredAction = await (await ensureOk(await api.get(raPath), 'read required action')).json();
  if (!requiredAction.enabled) {
    await ensureOk(
      await api.put(raPath, { data: { ...requiredAction, enabled: true } }),
      'enable webauthn-register-passwordless',
    );
  }

  await ensureOk(
    await api.post(`/admin/realms/${REALM}/clients`, {
      data: {
        clientId: CLIENT_ID,
        publicClient: true,
        standardFlowEnabled: true,
        directAccessGrantsEnabled: false,
        redirectUris: [REDIRECT_URI],
      },
    }),
    'create client',
  );

  const userRes = await ensureOk(
    await api.post(`/admin/realms/${REALM}/users`, {
      data: {
        username: USER.email,
        email: USER.email,
        firstName: 'Theme',
        lastName: 'Guest',
        enabled: true,
        emailVerified: true,
        requiredActions: ['webauthn-register-passwordless'],
        credentials: [{ type: 'password', value: USER.password, temporary: false }],
      },
    }),
    'create user',
  );
  const userId = userRes.headers()['location']?.split('/').pop();
  if (!userId) {
    throw new Error('create user: Keycloak returned no Location header');
  }
  return userId;
}

test('Register Passkey runs the page script and Keycloak stores the passkey', async ({ page, context }) => {
  const seedApi = await adminApi();
  const userId = await seedRealm(seedApi);
  await seedApi.dispose();

  const pageErrors: string[] = [];
  const failedResources: string[] = [];
  const erroredUrls = new Set<string>();
  page.on('pageerror', (err) => pageErrors.push(`${err.name}: ${err.message} (${page.url()})`));
  page.on('response', (res) => {
    if (res.url().startsWith(KC_URL) && res.status() >= 400) {
      erroredUrls.add(res.url());
      failedResources.push(`${res.status()} ${res.url()}`);
    }
  });
  page.on('requestfailed', (req) => {
    // Chrome also aborts the body of a 4xx script; that one is already listed.
    if (req.url().startsWith(KC_URL) && !erroredUrls.has(req.url())) {
      failedResources.push(`${req.failure()?.errorText ?? 'failed'} ${req.url()}`);
    }
  });

  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });

  let clientRedirect: URL | undefined;
  page.on('request', (req) => {
    if (req.isNavigationRequest() && req.url().startsWith(REDIRECT_URI)) {
      clientRedirect = new URL(req.url());
    }
  });

  await page.goto(
    `${KC_URL}/realms/${REALM}/protocol/openid-connect/auth?${new URLSearchParams({
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: 'code',
      scope: 'openid',
    })}`,
  );

  // login.ftl keeps the password form behind the admin-login toggle.
  await page.locator('#show-admin-login').click();
  await page.locator('#username').fill(USER.email);
  await page.locator('#password').fill(USER.password);
  await page.locator('#admin-login-form button[type="submit"]').click();

  // The platform template, not Keycloak's base one.
  await expect(page.locator('h2', { hasText: 'Set Up Your Passkey' })).toBeVisible();
  await page.locator('#registerBtn').click();

  // Either the ceremony completes and Keycloak redirects back to the client, or
  // the page script has already thrown — don't sit out the timeout for that.
  await expect
    .poll(() => pageErrors.length > 0 || clientRedirect !== undefined, { timeout: 30_000 })
    .toBe(true);

  expect(
    { pageErrors, failedResources },
    'uncaught JavaScript errors / failed Keycloak requests in the theme',
  ).toEqual({ pageErrors: [], failedResources: [] });
  expect(
    clientRedirect?.searchParams.get('code'),
    'Keycloak should finish the required action and redirect to the client with a code',
  ).toBeTruthy();

  const { credentials } = await cdp.send('WebAuthn.getCredentials', { authenticatorId });
  expect(credentials, 'virtual authenticator should hold the new passkey').toHaveLength(1);

  const verifyApi = await adminApi();
  const storedCredentials = await (
    await ensureOk(await verifyApi.get(`/admin/realms/${REALM}/users/${userId}/credentials`), 'list credentials')
  ).json();
  expect(storedCredentials.map((c: { type: string }) => c.type)).toContain('webauthn-passwordless');
  const user = await (
    await ensureOk(await verifyApi.get(`/admin/realms/${REALM}/users/${userId}`), 'read user')
  ).json();
  expect(user.requiredActions ?? []).not.toContain('webauthn-register-passwordless');
  await verifyApi.dispose();
});
