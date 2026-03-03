import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';

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

  test('login redirects to Keycloak, not native login form', async ({ memberPage: page }) => {
    // Use a fresh browser context without any existing session cookies.
    // This simulates an unauthenticated user visiting Nextcloud for the first time.
    const freshContext = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true });
    const freshPage = await freshContext.newPage();

    const response = await freshPage.goto(`${urls.files}/login`).catch(() => null);

    if (!response) {
      await freshPage.close();
      await freshContext.close();
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
      return; // unreachable but satisfies TS
    }

    // Follow redirects and check where we end up
    await freshPage.waitForLoadState('networkidle').catch(() => {});
    const finalUrl = freshPage.url();

    // The native Nextcloud login page has a visible password field.
    // If allow_multiple_user_backends=0 (correct), /login auto-redirects to
    // /apps/user_oidc/login/1 which then redirects to Keycloak (auth.*).
    // If allow_multiple_user_backends=1 (broken), /login shows the native form.
    const hasPasswordField = await freshPage
      .locator('input[name="password"], #password')
      .isVisible({ timeout: 3_000 })
      .catch(() => false);

    const onNativeLogin = !finalUrl.includes('user_oidc') &&
      !finalUrl.includes('auth.') &&
      hasPasswordField;

    await freshPage.close();
    await freshContext.close();

    expect(
      onNativeLogin,
      'Nextcloud is showing its native login page instead of redirecting to Keycloak. ' +
      'This means allow_multiple_user_backends is set to 1 (should be 0). ' +
      'Fix: run "php occ config:app:set --value=0 user_oidc allow_multiple_user_backends" ' +
      'or redeploy Nextcloud to trigger the before-starting hook.'
    ).toBe(false);
  });

  test('calendar app responds (pretty URLs working)', async ({ memberPage: page }) => {
    // Test that /apps/calendar doesn't return a raw Apache 404.
    // This catches missing .htaccess pretty URL rewrite rules
    // (occ maintenance:update:htaccess not run, or overwrite.cli.url not set).
    const freshContext = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true });
    const freshPage = await freshContext.newPage();

    const response = await freshPage.goto(`${urls.files}/apps/calendar`).catch(() => null);

    if (!response) {
      await freshPage.close();
      await freshContext.close();
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
      return;
    }

    const status = response.status();
    const bodyText = await freshPage.locator('body').textContent().catch(() => '') || '';
    await freshPage.close();
    await freshContext.close();

    // A raw Apache 404 (not PHP) indicates broken .htaccess rewrite rules.
    // Valid responses: 302 (redirect to login/OIDC), 401 (unauthorized), 200 (loaded).
    // Invalid: 404 with Apache error page text.
    const isApache404 = status === 404 &&
      /Apache.*Server|The requested URL was not found/i.test(bodyText);

    expect(
      isApache404,
      'Nextcloud /apps/calendar returns Apache 404 — .htaccess pretty URL rewrite rules are missing. ' +
      'Fix: run "php occ maintenance:update:htaccess" (requires overwrite.cli.url to be set).'
    ).toBe(false);
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

    // Wait for files view (retries if Nextcloud is in maintenance mode during HPA scale-up)
    await waitForNextcloudReady(page);

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
