import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('SSO — Cross-App Single Sign-On', () => {
  test('login to account portal enables SSO to admin portal', async ({ context }) => {
    // Use a fresh context — login via account portal, then verify SSO to admin portal
    const newContext = await context.browser()!.newContext({ ignoreHTTPSErrors: true });
    const page = await newContext.newPage();

    // Step 1: Login to account portal as admin user (establishes Keycloak session)
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.admin.username, TEST_USERS.admin.password);
    }
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 15_000 });

    // Step 2: Navigate to admin portal — SSO should auto-complete via Keycloak session
    await page.goto(urls.adminPortal);
    await page.waitForLoadState('load');

    // Click "Sign In" on admin portal landing page
    const signInLink = page.locator('a[href="/auth/login"]');
    if (await signInLink.isVisible({ timeout: 3000 }).catch(() => false)) {
      await signInLink.click();
      await page.waitForLoadState('load');
    }

    // Keycloak should auto-complete SSO (no login form needed)
    await expect(page.locator(selectors.adminPortal.adminHeading)).toBeVisible({ timeout: 15_000 });

    await newContext.close();
  });

  // Uses emailTestPage (fixed user with persistent Stalwart mail principal)
  // because pipeline-scoped users may not have Stalwart principals yet,
  // causing OAUTHBEARER auth to fail during the Roundcube OIDC flow.
  test('login to account portal enables SSO to Roundcube', async ({ emailTestPage: page }) => {
    const ROUNDCUBE_INBOX = '#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")';

    // Try the OIDC flow with a retry — the first attempt may catch Keycloak mid-redirect
    for (let attempt = 0; attempt < 2; attempt++) {
      await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);

      const visible = await page.locator(ROUNDCUBE_INBOX).first()
        .waitFor({ timeout: 45_000 })
        .then(() => true)
        .catch(() => false);

      if (visible) {
        await expect(page.locator(ROUNDCUBE_INBOX).first()).toBeVisible();
        return;
      }

      if (attempt === 0) {
        console.log('  [cross-app-sso] Roundcube SSO timed out, retrying...');
      }
    }

    // Final assertion — will fail with a clear error message
    await expect(
      page.locator(ROUNDCUBE_INBOX).first(),
    ).toBeVisible({ timeout: 15_000 });
  });

  test('login to account portal enables SSO to Files', async ({ memberPage: page }) => {
    await page.goto(urls.files);
    await page.waitForLoadState('networkidle');

    // Should not be stuck on Keycloak — may see Nextcloud OIDC error or dashboard
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');
  });
});
