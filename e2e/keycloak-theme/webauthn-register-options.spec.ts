import { randomUUID } from 'crypto';
import { test, expect, type Page } from '@playwright/test';
import { adminApi, authUrl, createUser, ensureOk, KC_URL, passwordLogin, recreateRealm, REDIRECT_URI } from './helpers';

/**
 * What webauthn-register.ftl hands to navigator.credentials.create(), and what
 * it does when that call fails.
 *
 * Regression guard for a 2026-10 production failure: a guest on Safari 15.3
 * could not register a passkey. Keycloak renders every unset WebAuthn policy
 * value as the literal "not specified", and the template passed
 * `attestation: "not specified"` straight through. Chromium ignores unknown
 * enum values, but WebKit treated these members as strict IDL enums until late
 * 2025 and rejected the whole call with "TypeError: Type error". Chromium (and
 * so the virtual-authenticator spec next door) cannot reproduce that, so this
 * spec captures the options and checks every enum member against its allowed
 * values instead.
 *
 * The guest then had no way out: with the mt-setup-info cookie present (set by
 * the account portal's /beginSetup), a failed registration must offer email
 * sign-in on the page instead of posting the error to Keycloak's generic error
 * page.
 *
 * Run via ci/scripts/keycloak-theme-test.sh, which boots the pinned image.
 */

const CLIENT_ID = 'theme-test-options';

const ALLOWED: Record<string, string[]> = {
  attestation: ['none', 'indirect', 'direct', 'enterprise'],
  authenticatorAttachment: ['platform', 'cross-platform'],
  residentKey: ['discouraged', 'preferred', 'required'],
  userVerification: ['required', 'preferred', 'discouraged'],
};

const POLICIES = {
  // As docs/import-keycloak-realm.sh configures tenant realms (and prod has).
  production: {
    webAuthnPolicyPasswordlessAttestationConveyancePreference: 'not specified',
    webAuthnPolicyPasswordlessAuthenticatorAttachment: 'not specified',
    webAuthnPolicyPasswordlessRequireResidentKey: 'Yes',
    webAuthnPolicyPasswordlessUserVerificationRequirement: 'required',
  },
  // Every guarded member unset.
  allUnspecified: {
    webAuthnPolicyPasswordlessAttestationConveyancePreference: 'not specified',
    webAuthnPolicyPasswordlessAuthenticatorAttachment: 'not specified',
    webAuthnPolicyPasswordlessRequireResidentKey: 'not specified',
    webAuthnPolicyPasswordlessUserVerificationRequirement: 'not specified',
  },
};

/** Realm + client + a user who must register a passkey. Returns credentials and id. */
async function seed(realm: string, policy: Record<string, string>) {
  const api = await adminApi();
  await recreateRealm(api, realm, {
    displayName: 'Theme Test',
    webAuthnPolicyPasswordlessRpEntityName: 'Theme Test',
    webAuthnPolicyPasswordlessSignatureAlgorithms: ['ES256', 'RS256'],
    webAuthnPolicyPasswordlessRpId: new URL(KC_URL).hostname,
    webAuthnPolicyPasswordlessCreateTimeout: 0,
    webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister: false,
    ...policy,
  });

  const raPath = `/admin/realms/${realm}/authentication/required-actions/webauthn-register-passwordless`;
  const requiredAction = await (await ensureOk(await api.get(raPath), 'read required action')).json();
  if (!requiredAction.enabled) {
    await ensureOk(await api.put(raPath, { data: { ...requiredAction, enabled: true } }), 'enable required action');
  }
  await ensureOk(
    await api.post(`/admin/realms/${realm}/clients`, {
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

  const user = { email: `guest@${realm}.invalid`, password: randomUUID() };
  const userId = await createUser(api, realm, {
    username: user.email,
    email: user.email,
    firstName: 'Theme',
    lastName: 'Guest',
    enabled: true,
    emailVerified: true,
    requiredActions: ['webauthn-register-passwordless'],
    credentials: [{ type: 'password', value: user.password, temporary: false }],
  });
  await api.dispose();
  return { ...user, userId };
}

/**
 * Replace navigator.credentials.create with a recorder that rejects the way
 * Safari 15 did, and report a platform authenticator (a Touch ID Mac) so the
 * page shows its normal passkey button rather than the no-authenticator banner.
 * Returns the publicKey options of every call, collected test-side because a
 * failed registration may navigate away from the page.
 */
async function stubWebAuthn(page: Page): Promise<Record<string, unknown>[]> {
  const calls: Record<string, unknown>[] = [];
  await page.exposeFunction('__recordCreate', (publicKey: Record<string, unknown>) => {
    calls.push(publicKey);
  });
  await page.addInitScript(() => {
    const w = window as unknown as { __recordCreate: (publicKey: unknown) => Promise<void> };
    const describe = (value: unknown): unknown => {
      if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return '<bytes>';
      if (Array.isArray(value)) return value.map(describe);
      if (value && typeof value === 'object') {
        return Object.fromEntries(
          Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, describe(v)]),
        );
      }
      // Keep explicit `undefined` members visible (JSON would drop them).
      return value === undefined ? '<undefined>' : value;
    };
    Object.defineProperty(CredentialsContainer.prototype, 'create', {
      configurable: true,
      value: (options: { publicKey: unknown }) =>
        w.__recordCreate(describe(options.publicKey)).then(() => Promise.reject(new TypeError('Type error'))),
    });
    Object.defineProperty(PublicKeyCredential, 'isUserVerifyingPlatformAuthenticatorAvailable', {
      configurable: true,
      value: () => Promise.resolve(true),
    });
  });
  return calls;
}

async function openPasskeyPage(page: Page, realm: string, email: string, password: string): Promise<void> {
  await page.goto(authUrl(realm, CLIENT_ID));
  await passwordLogin(page, email, password);
  await expect(page.locator('h2', { hasText: 'Set Up Your Passkey' })).toBeVisible();
}

for (const [name, policy] of Object.entries(POLICIES)) {
  test(`create() gets only valid enum values (${name} policy)`, async ({ page }) => {
    const realm = `theme-test-options-${name.toLowerCase()}`;
    const user = await seed(realm, policy);
    const calls = await stubWebAuthn(page);
    await openPasskeyPage(page, realm, user.email, user.password);

    await page.locator('#registerBtn').click();
    await expect.poll(() => calls.length).toBe(1);
    const publicKey = calls[0];

    expect(JSON.stringify(publicKey), 'no Keycloak "not specified" placeholder may reach the browser').not.toContain(
      'not specified',
    );
    const members: Record<string, unknown> = {
      ...('attestation' in publicKey ? { attestation: publicKey.attestation } : {}),
      ...((publicKey.authenticatorSelection as Record<string, unknown> | undefined) ?? {}),
    };
    for (const [member, allowed] of Object.entries(ALLOWED)) {
      if (member in members) {
        expect(allowed, `${member} must be absent or one of ${allowed.join('/')}`).toContain(members[member]);
      }
    }
    if (name === 'production') {
      expect(members).toMatchObject({ residentKey: 'required', requireResidentKey: true, userVerification: 'required' });
      expect(publicKey).not.toHaveProperty('attestation');
    }
  });
}

test('failed registration with a setup cookie offers email sign-in instead of posting the error', async ({
  page,
  context,
}) => {
  const realm = 'theme-test-options-fallback';
  const user = await seed(realm, POLICIES.production);
  const calls = await stubWebAuthn(page);
  const setupToken = `${Math.floor(Date.now() / 1000)}:${'ab'.repeat(32)}`;
  await context.addCookies([
    {
      name: 'mt-setup-info',
      value: Buffer.from(JSON.stringify({ userId: user.userId, token: setupToken })).toString('base64url'),
      url: KC_URL,
    },
  ]);

  const posts: string[] = [];
  page.on('request', (req) => {
    if (req.method() === 'POST' && req.url().includes('/login-actions/required-action')) posts.push(req.url());
  });

  await openPasskeyPage(page, realm, user.email, user.password);
  await expect(page.locator('#magic-link-subtle')).toBeVisible();
  await page.locator('#registerBtn').click();

  await expect(page.locator('#no-platform-auth-banner')).toContainText("Passkey setup didn't work");
  const magicLink = page.locator('#magic-link-btn');
  await expect(magicLink).toBeVisible();
  const href = new URL((await magicLink.getAttribute('href')) ?? '');
  expect(href.pathname).toBe('/switch-to-magic-link');
  expect(href.searchParams.get('userId')).toBe(user.userId);
  expect(href.searchParams.get('token')).toBe(setupToken);
  expect(href.searchParams.get('reason')).toBe('TypeError');
  expect(href.searchParams.get('next')).toContain('/login-actions/');

  await expect(page.locator('#registerBtn')).toBeHidden();
  await expect(page.locator('#register-btn-secondary-link')).toHaveText('Try passkey again');
  await expect(page.locator('#magic-link-subtle')).toBeHidden();
  expect(posts, 'the error must not be posted to Keycloak while a fallback is offered').toEqual([]);

  // "Try passkey again" re-runs the ceremony on the same page.
  expect(calls).toHaveLength(1);
  await page.locator('#register-btn-secondary-link').click();
  await expect.poll(() => calls.length).toBe(2);
  expect(posts).toEqual([]);
});

test('failed registration without a setup cookie still reports the error to Keycloak', async ({ page }) => {
  const realm = 'theme-test-options-nocookie';
  const user = await seed(realm, POLICIES.production);
  await stubWebAuthn(page);
  await openPasskeyPage(page, realm, user.email, user.password);

  const post = page.waitForRequest(
    (req) => req.method() === 'POST' && req.url().includes('/login-actions/required-action'),
  );
  await page.locator('#registerBtn').click();
  const form = new URLSearchParams((await post).postData() ?? '');
  expect(form.get('error')).toBe('TypeError: Type error');
});
