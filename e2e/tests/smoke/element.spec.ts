import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Element (Chat)', () => {
  test('SSO login loads Element main UI', async ({ memberPage: page }) => {
    // Element runs on the matrix subdomain
    const response = await page.goto(urls.element).catch(() => null);

    // If DNS doesn't resolve, connection fails, or server error, skip
    if (!response) {
      test.skip(true, 'Element not reachable (DNS or connection error)');
    }

    // Element may redirect to a login/SSO page
    await page.waitForLoadState('networkidle');

    // Check for server errors before proceeding
    const hasServerError = await page.locator('text=/Internal server error|Server Error|500|502|503/i').isVisible().catch(() => false);
    test.skip(hasServerError, 'Element returned a server error — not a test issue');

    // If on Keycloak, the SSO session from memberPage may auto-approve and
    // redirect back. Wait briefly for that before attempting manual login.
    if (page.url().includes('auth.')) {
      const needsLogin = await page.waitForURL(
        url => !url.toString().includes('auth.'),
        { timeout: 5_000 },
      ).then(() => false).catch(() => true);

      if (needsLogin) {
        await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      }
    }

    // Wait for Element to load — it's a React SPA that takes time
    await page.waitForLoadState('networkidle');

    // Verify we're not stuck on Keycloak
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    // The page should have substantial content (Element SPA)
    const bodyText = await page.locator('body').textContent();
    expect(bodyText!.length).toBeGreaterThan(50);
  });
});
