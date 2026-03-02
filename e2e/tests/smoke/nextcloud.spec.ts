import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { Page } from '@playwright/test';

/**
 * Handle Nextcloud login — covers both Keycloak redirect and Nextcloud's
 * native login page. Sometimes the OIDC auto-redirect fails and Nextcloud
 * shows its own login form instead. When that happens, trigger the OIDC
 * flow manually by navigating to the user_oidc login endpoint.
 */
async function handleNextcloudLogin(page: Page): Promise<void> {
  if (page.url().includes('auth.')) {
    // Landed on Keycloak — complete the login flow
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('networkidle').catch(() => {});
    return;
  }

  // Check if we're on Nextcloud's native login page (not the app itself)
  const onNativeLogin = page.url().includes('/login') &&
    !page.url().includes('user_oidc') &&
    await page.locator('input[name="password"], #password').isVisible({ timeout: 2_000 }).catch(() => false);

  if (onNativeLogin) {
    // Trigger OIDC flow — navigate to the user_oidc login endpoint,
    // which redirects to Keycloak. The existing SSO session should auto-complete.
    // Use a timeout since this can hang when Nextcloud can't reach Keycloak.
    const oidcResponse = await page.goto(`${urls.files}/apps/user_oidc/login/1`, { timeout: 30_000 }).catch(() => null);

    if (!oidcResponse) {
      // OIDC endpoint timed out — Nextcloud can't reach Keycloak, nothing we can do
      return;
    }

    await page.waitForLoadState('networkidle').catch(() => {});

    // If Keycloak session expired, we'll land on the Keycloak login page
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }
  }
}

test.describe('Smoke — Nextcloud (Files)', () => {
  test('Nextcloud server responds', async ({ memberPage: page }) => {
    // Use a fresh page to avoid SSO auto-login triggering the OIDC flow
    const freshPage = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true }).then(ctx => ctx.newPage());

    const response = await freshPage.goto(urls.files).catch(() => null);
    const finalUrl = freshPage.url();
    const status = response?.status() ?? 0;
    await freshPage.close();

    if (!response) {
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
    }

    // Nextcloud's OIDC module failing to reach Keycloak (PROXY protocol issue)
    // causes a 404 at /apps/user_oidc/login/1. This is now a real failure since
    // PR #87 fixed the issue with hostAliases + internal ingress.
    const isOidcFailure = status === 404 && finalUrl.includes('user_oidc');
    expect(isOidcFailure, 'Nextcloud OIDC login returns 404 — cannot reach Keycloak (PROXY protocol issue)').toBe(false);

    // Any HTTP response means the server is up — should not be a 5xx
    expect(status, `Nextcloud returned HTTP ${status}`).toBeLessThan(500);
  });

  test('SSO login loads Nextcloud', async ({ memberPage: page }) => {
    const response = await page.goto(urls.files).catch(() => null);

    if (!response) {
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
    }

    await page.waitForLoadState('networkidle').catch(() => {});

    await handleNextcloudLogin(page);

    // Nextcloud is a heavy PHP app — give it time to load after OIDC callback
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.waitForTimeout(3_000);

    const pageText = await page.locator('body').textContent().catch(() => '') || '';

    // OIDC login must succeed — the session cookie fix (cookie_secure) ensures
    // the PHP session survives the redirect from Keycloak back to Nextcloud
    const hasOidcError = /Could not reach the OpenID Connect provider/i.test(pageText);
    const hasOidcLoginFailure = page.url().includes('user_oidc');
    expect(hasOidcError, 'Nextcloud OIDC: "Could not reach the OpenID Connect provider"').toBe(false);
    expect(hasOidcLoginFailure, 'Nextcloud OIDC: stuck on user_oidc login page').toBe(false);

    // Check for server/client errors
    const hasServerError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    const hasClientError = /Page not found|Not Found|\b404\b/i.test(pageText);
    expect(hasServerError, 'Nextcloud returned a server error').toBe(false);
    expect(hasClientError, 'Nextcloud returned a client error (404)').toBe(false);

    // Verify we left the auth pages
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    // Should have Nextcloud content — check for known selectors first,
    // then fall back to page content length (Nextcloud versions vary)
    const hasContent = await page
      .locator('#app-content, #app-dashboard, .files-list, [class*="app-content"], #content')
      .first()
      .isVisible({ timeout: 15_000 })
      .catch(() => false);

    if (!hasContent) {
      // Fallback: the page should have substantial content if Nextcloud loaded
      const htmlLength = (await page.content()).length;
      expect(htmlLength).toBeGreaterThan(1000);
    }
  });

  test('can upload a file when Nextcloud is accessible', async ({ memberPage: page }) => {
    const response = await page.goto(`${urls.files}/apps/files/`).catch(() => null);

    if (!response) {
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
    }

    await page.waitForLoadState('networkidle');

    await handleNextcloudLogin(page);

    // OIDC login must succeed before we can test file upload
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasError = /Could not reach|Server Error|Internal Server Error|Forbidden|\b500\b|\b403\b/i.test(pageText);
    const stuckOnOidc = page.url().includes('user_oidc');
    expect(hasError, 'Nextcloud returned an error page').toBe(false);
    expect(stuckOnOidc, 'Nextcloud OIDC login failed — stuck on user_oidc page').toBe(false);

    // Wait for files view
    await page.waitForSelector('#app-content, .files-list, [class*="app-content"]', { timeout: 30_000 });

    // Nextcloud has a hidden file input for uploads
    const fileInput = page.locator('input[type="file"]');
    if (await fileInput.count() > 0) {
      const testFileName = `e2e-test-${Date.now()}.txt`;
      await fileInput.first().setInputFiles({
        name: testFileName,
        mimeType: 'text/plain',
        buffer: Buffer.from('E2E test file content'),
      });

      // Wait for upload to complete
      await page.waitForTimeout(3_000);
      const pageContent = await page.content();
      expect(pageContent).toContain('e2e-test');
    }
  });
});
