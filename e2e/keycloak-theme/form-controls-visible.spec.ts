import { randomUUID } from 'crypto';
import { test, expect } from '@playwright/test';
import {
  adminApi,
  authUrl,
  createUser,
  ensureOk,
  expectClientRedirectWithCode,
  passwordLogin,
  recreateRealm,
  REDIRECT_URI,
  watchClientRedirect,
} from './helpers';

/**
 * Pages the platform theme does NOT override still get its stylesheet, so a
 * global rule in login/resources/css/styles.css can hide their controls.
 *
 * Regression guard for the 2026-09 production break of guest onboarding:
 * styles.css hid `#kc-form-buttons`, `#kc-form-options` and every
 * `input#username` on all pages (meant for an old login form). Keycloak's stock
 * login-update-profile.ftl keeps its only Submit inside #kc-form-buttons, and
 * guests are created without a first/last name, so every guest landed on an
 * "Update Account Information" form with no button.
 *
 * The realm below mirrors the login-relevant settings of
 * docs/keycloak-realm-config.json.tpl with Keycloak's default user profile
 * (firstName/lastName required for users, as in production).
 *
 * Run via ci/scripts/keycloak-theme-test.sh, which boots the pinned image.
 */

const REALM = 'theme-test-controls';
const CLIENT_ID = 'theme-test-controls';
const CONSENT_CLIENT_ID = 'theme-test-consent';

test.beforeAll(async () => {
  const api = await adminApi();
  await recreateRealm(api, REALM, {
    registrationAllowed: false,
    loginWithEmailAllowed: true,
    duplicateEmailsAllowed: false,
    resetPasswordAllowed: true,
    editUsernameAllowed: false,
  });
  for (const clientId of [CLIENT_ID, CONSENT_CLIENT_ID]) {
    await ensureOk(
      await api.post(`/admin/realms/${REALM}/clients`, {
        data: {
          clientId,
          publicClient: true,
          standardFlowEnabled: true,
          directAccessGrantsEnabled: false,
          consentRequired: clientId === CONSENT_CLIENT_ID,
          redirectUris: [REDIRECT_URI],
        },
      }),
      `create client ${clientId}`,
    );
  }
  await api.dispose();
});

test('profile page for a guest without a name has a visible Submit that completes login', async ({ page }) => {
  const email = `nameless-guest@theme-test.invalid`;
  const password = randomUUID();
  const seedApi = await adminApi();
  // Same shape as account-portal createGuestUser(): username = email, no names.
  const userId = await createUser(seedApi, REALM, {
    username: email,
    email,
    enabled: true,
    emailVerified: true,
    credentials: [{ type: 'password', value: password, temporary: false }],
  });
  await seedApi.dispose();

  const clientRedirect = watchClientRedirect(page);
  await page.goto(authUrl(REALM, CLIENT_ID));
  await passwordLogin(page, email, password);

  const form = page.locator('#kc-update-profile-form');
  await expect(form, 'Keycloak should ask the nameless user for their profile').toBeVisible();
  const submit = form.locator('input[type="submit"]');
  await expect(submit, 'the profile form must show its Submit button').toBeVisible();

  await form.locator('#firstName').fill('Theme');
  await form.locator('#lastName').fill('Guest');
  await submit.click();
  await expectClientRedirectWithCode(clientRedirect, 'submitting the profile form');

  const verifyApi = await adminApi();
  const user = await (
    await ensureOk(await verifyApi.get(`/admin/realms/${REALM}/users/${userId}`), 'read user')
  ).json();
  expect({ firstName: user.firstName, lastName: user.lastName }).toEqual({ firstName: 'Theme', lastName: 'Guest' });
  await verifyApi.dispose();
});

test('consent page keeps its Yes/No buttons visible', async ({ page }) => {
  const email = `consenting-user@theme-test.invalid`;
  const password = randomUUID();
  const seedApi = await adminApi();
  await createUser(seedApi, REALM, {
    username: email,
    email,
    firstName: 'Theme',
    lastName: 'User',
    enabled: true,
    emailVerified: true,
    credentials: [{ type: 'password', value: password, temporary: false }],
  });
  await seedApi.dispose();

  const clientRedirect = watchClientRedirect(page);
  await page.goto(authUrl(REALM, CONSENT_CLIENT_ID));
  await passwordLogin(page, email, password);

  const accept = page.locator('#kc-login');
  await expect(accept, 'the consent page must show its accept button').toBeVisible();
  await expect(page.locator('#kc-cancel'), 'the consent page must show its decline button').toBeVisible();
  await accept.click();
  await expectClientRedirectWithCode(clientRedirect, 'granting consent');
});
