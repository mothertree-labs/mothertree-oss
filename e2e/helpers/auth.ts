import { Page } from '@playwright/test';
import { selectors } from './selectors';
import { urls } from './urls';

/**
 * Navigate the Keycloak OIDC password login flow.
 *
 * There are two Keycloak login page variants:
 *
 * **login.ftl** (passkey-first page):
 *   - Has #passkey-login-btn and #show-admin-login toggle
 *   - Click #show-admin-login to reveal #admin-login-form
 *   - Fill #password (and #username if it's a text input, not hidden)
 *   - Submit the form
 *
 * **login-username.ftl** (step-by-step flow):
 *   - Has visible #username text input + .continue-btn
 *   - After submitting username, lands on WebAuthn or password page
 *   - May need to click #try-another-way → select "Password" authenticator
 *   - Fill #mt-password and submit
 */
export async function keycloakLogin(
  page: Page,
  username: string,
  password: string,
): Promise<void> {
  const kc = selectors.keycloak;

  // Wait for any Keycloak login element to appear
  await page.waitForSelector(
    [kc.passKeyLoginBtn, `${kc.usernameInput}:visible`, kc.passwordInput, kc.tryAnotherWay].join(', '),
    { timeout: 15_000, state: 'attached' },
  );

  // ── login.ftl variant: passkey-first page with admin toggle ──
  const passkeyBtn = page.locator(kc.passKeyLoginBtn);
  if (await passkeyBtn.isVisible().catch(() => false)) {
    // Click "Admin login with password" to reveal the password form
    const adminToggle = page.locator(kc.adminLoginToggle);
    await adminToggle.click();

    // Wait for the admin login form to become visible
    await page.waitForSelector(`${kc.adminLoginForm}.visible, ${kc.adminLoginForm}:visible`, { timeout: 5_000 }).catch(() => {});

    // Fill username if it's a visible text input (not pre-filled hidden)
    const usernameInput = page.locator(`${kc.adminLoginForm} input#username[type="text"]`);
    if (await usernameInput.isVisible().catch(() => false)) {
      await usernameInput.fill(username);
    }

    // Fill password and submit
    await page.locator(kc.adminPasswordInput).fill(password);
    await page.locator(`${kc.adminLoginForm} button[type="submit"]`).click();

    // Wait for redirect away from Keycloak
    await page.waitForFunction(
      (host: string) => !window.location.hostname.includes(host),
      'auth.',
      { timeout: 15_000 },
    );
    return;
  }

  // ── login-username.ftl variant: step-by-step flow ──

  // If visible username field, fill it and continue
  const usernameField = page.locator(`${kc.usernameInput}:visible`);
  if (await usernameField.count() > 0) {
    await usernameField.fill(username);
    await page.locator(kc.continueBtn).click();
    // Wait for next step — or a Keycloak error (e.g. user doesn't exist)
    const nextStep = page.locator(
      `${kc.passwordInput}, ${kc.tryAnotherWay}, .authenticator-link`,
    );
    const kcError = page.locator('.alert-error, .kc-feedback-text, #input-error');
    const matched = await Promise.race([
      nextStep.first().waitFor({ timeout: 10_000, state: 'attached' }).then(() => 'next' as const),
      kcError.first().waitFor({ timeout: 10_000, state: 'attached' }).then(() => 'error' as const),
    ]).catch(() => 'timeout' as const);

    if (matched === 'error') {
      const errorText = await kcError.first().textContent().catch(() => '(unknown error)');
      throw new Error(
        `Keycloak login failed for "${username}": ${errorText?.trim()}\n` +
        'Hint: The test user may not exist. In CI, users must be pre-provisioned. ' +
        'Run: ./scripts/dev-test-users.sh -e dev -t <tenant> create <username> --password <password>',
      );
    }
    if (matched === 'timeout') {
      const pageText = await page.locator('body').textContent().catch(() => '');
      throw new Error(
        `Keycloak login timed out after username step for "${username}". ` +
        `URL: ${page.url()}\nPage text: ${pageText?.substring(0, 200)}`,
      );
    }
  }

  // If "Try another way" is visible → we're on the WebAuthn page
  const tryAnotherWay = page.locator(kc.tryAnotherWay);
  if (await tryAnotherWay.isVisible().catch(() => false)) {
    await tryAnotherWay.click();
    await page.waitForSelector(
      `${kc.passwordInput}, .authenticator-link`,
      { timeout: 10_000, state: 'attached' },
    );
  }

  // If we see the authenticator selection page, click the password option
  const passwordOption = page.locator(kc.passwordAuthLink);
  if (await passwordOption.isVisible().catch(() => false)) {
    await passwordOption.click();
    await page.waitForSelector(kc.passwordInput, { timeout: 10_000 });
  }

  // Fill password and submit
  await page.waitForSelector(kc.passwordInput, { timeout: 10_000 });
  await page.locator(kc.passwordInput).fill(password);
  await page.locator(kc.passwordSubmitBtn).click();

  // Wait for redirect away from Keycloak — or an error (wrong password)
  const redirected = await page.waitForFunction(
    (host: string) => !window.location.hostname.includes(host),
    'auth.',
    { timeout: 15_000 },
  ).then(() => true).catch(() => false);

  if (!redirected) {
    const errorEl = page.locator('.alert-error, .kc-feedback-text, #input-error');
    const errorText = await errorEl.first().textContent().catch(() => null);
    if (errorText) {
      throw new Error(
        `Keycloak login failed for "${username}": ${errorText.trim()}\n` +
        'Hint: Check that the test user password is correct.',
      );
    }
    throw new Error(
      `Keycloak login did not redirect after password submission for "${username}". ` +
      `URL: ${page.url()}`,
    );
  }
}

/**
 * Login to a specific app by navigating to it (triggers OIDC redirect)
 * and completing the Keycloak flow.
 */
export async function loginToApp(
  page: Page,
  appUrl: string,
  username: string,
  password: string,
): Promise<void> {
  await page.goto(appUrl);

  // If we're already logged in (cookie still valid), no need to auth
  if (!page.url().includes('auth.')) {
    return;
  }

  await keycloakLogin(page, username, password);
}

/**
 * Navigate to a portal that has an unauthenticated landing page with a "Sign In" link.
 * Click "Sign In" to trigger OIDC, then complete Keycloak login if needed.
 * If already authenticated (SSO session valid), Keycloak auto-redirects back.
 */
export async function loginToPortal(
  page: Page,
  portalUrl: string,
  authenticatedSelector: string,
  username: string,
  password: string,
): Promise<void> {
  await page.goto(portalUrl);

  // Check if already authenticated (dashboard loaded directly)
  const isAuthenticated = await page.locator(authenticatedSelector).isVisible({ timeout: 2000 }).catch(() => false);
  if (isAuthenticated) return;

  // On the landing page — click "Sign In" to trigger OIDC
  const signInLink = page.locator('a[href="/auth/login"]');
  if (await signInLink.isVisible({ timeout: 2000 }).catch(() => false)) {
    await signInLink.click();

    // Wait for either Keycloak (needs credentials) or redirect back (SSO)
    await page.waitForURL(/auth\.|\/dashboard|\/home/, { timeout: 15_000 }).catch(() => {});

    // If on Keycloak, complete login
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, username, password);
    }
  } else if (page.url().includes('auth.')) {
    // Directly on Keycloak (e.g., auto-redirect from app)
    await keycloakLogin(page, username, password);
  }

  // Wait for the authenticated page to load
  await page.waitForSelector(authenticatedSelector, { timeout: 15_000 });
}

/**
 * Perform SSO login via the account portal, which sets the Keycloak session cookie.
 * Subsequent navigations to other apps should auto-SSO without re-entering credentials.
 */
export async function ssoLogin(
  page: Page,
  username: string,
  password: string,
): Promise<void> {
  await loginToApp(page, urls.accountPortal, username, password);
}
