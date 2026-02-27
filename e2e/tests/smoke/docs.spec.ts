import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Docs', () => {
  test('Docs frontend serves correctly', async ({ memberPage: page }) => {
    const response = await page.goto(urls.docs).catch(() => null);

    if (!response) {
      test.skip(true, 'Docs not reachable (DNS or connection error)');
    }

    // The Next.js frontend should serve static HTML (200)
    // OIDC redirects happen client-side after JS loads, so the initial response is the frontend
    const status = response!.status();
    expect(status, `Docs returned HTTP ${status} — expected 200`).toBe(200);
  });

  test('SSO login loads Docs main page', async ({ memberPage: page }) => {
    const response = await page.goto(urls.docs).catch(() => null);

    if (!response) {
      test.skip(true, 'Docs not reachable (DNS or connection error)');
    }

    // If redirected to Keycloak, complete login
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    }

    // Wait for the page to settle (OIDC callback may redirect)
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.waitForTimeout(2_000);

    // After OIDC callback, verify no server errors on the page
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasServerError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    const hasOidcError = /OIDC|OpenID|token|callback.*error/i.test(pageText);
    expect(hasServerError, 'Docs returned a server error after OIDC callback').toBe(false);
    expect(hasOidcError, 'Docs OIDC callback failed').toBe(false);

    // Verify we left the auth pages
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    // The page should have substantial content (Docs React app)
    const pageContent = await page.content();
    expect(pageContent.length).toBeGreaterThan(500);
  });
});
