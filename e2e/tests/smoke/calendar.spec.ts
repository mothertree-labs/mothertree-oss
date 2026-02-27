import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Calendar', () => {
  test('Calendar subdomain redirects to Nextcloud calendar app', async ({ memberPage: page }) => {
    // The calendar subdomain should redirect to /apps/calendar on the Nextcloud host.
    // If overwrite.cli.url is not set, Apache's .htaccess rewrite rules are missing,
    // and /apps/calendar returns a 404 instead of being routed through index.php.
    const response = await page.goto(urls.calendar).catch(() => null);

    if (!response) {
      test.skip(true, 'Calendar not reachable (DNS or connection error)');
    }

    const status = response!.status();

    // The redirect chain: calendar.dev.example.com → /apps/calendar
    // Without auth, Nextcloud redirects to OIDC login (302) which is fine.
    // A 404 means the .htaccess rewrite is broken (overwrite.cli.url not set).
    // A 500 means the server is broken.
    expect(status, `Calendar returned HTTP ${status} — expected redirect or login page, not error`).toBeLessThan(500);

    // After following redirects, we should NOT be on a plain Apache 404 page.
    // Apache 404 pages contain "The requested URL was not found on this server"
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const isApache404 = /The requested URL was not found on this server/i.test(pageText);
    expect(isApache404, 'Calendar returned Apache 404 — overwrite.cli.url likely not set (.htaccess missing rewrite rules)').toBe(false);
  });

  test('Calendar loads after SSO login', async ({ memberPage: page }) => {
    const response = await page.goto(urls.calendar).catch(() => null);

    if (!response) {
      test.skip(true, 'Calendar not reachable (DNS or connection error)');
    }

    await page.waitForLoadState('networkidle').catch(() => {});

    // Complete OIDC login if redirected to Keycloak
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    }

    // Wait for Nextcloud to load after OIDC callback
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.waitForTimeout(3_000);

    // Check for OIDC provider connectivity failures
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasOidcError = /Could not reach the OpenID Connect provider/i.test(pageText);
    expect(hasOidcError, 'Calendar OIDC login failed — backend cannot reach Keycloak').toBe(false);

    // Should not see Apache 404 (missing .htaccess rewrite)
    const isApache404 = /The requested URL was not found on this server/i.test(pageText);
    expect(isApache404, 'Calendar returned 404 — overwrite.cli.url not set').toBe(false);

    // Should not see generic errors
    const hasServerError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    expect(hasServerError, 'Calendar returned a server error').toBe(false);

    // After login, the URL should contain /apps/calendar (Nextcloud calendar app)
    const currentUrl = page.url();
    const isOnCalendar = currentUrl.includes('/apps/calendar');
    const isOnFiles = currentUrl.includes('files.') || currentUrl.includes('calendar.');
    expect(isOnCalendar || isOnFiles, `Expected to land on calendar app, but URL is: ${currentUrl}`).toBe(true);
  });
});
