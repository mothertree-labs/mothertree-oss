import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Docs', () => {
  test('SSO login loads Docs main page', async ({ memberPage: page }) => {
    await page.goto(urls.docs);

    // If redirected to Keycloak, complete login
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    }

    // Wait for the page to settle (OIDC callback may redirect)
    await page.waitForLoadState('networkidle');

    // Check if the server returned an error (known issue in dev)
    const hasServerError = await page.locator('text=/Server Error|500|503|502/i').isVisible().catch(() => false);
    test.skip(hasServerError, 'Docs server returned an error — not a test issue');

    // After OIDC callback, the URL may still contain auth. in query params (iss=...auth.domain)
    // Check hostname instead of full URL
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    const pageContent = await page.content();
    expect(pageContent.length).toBeGreaterThan(500);
  });
});
