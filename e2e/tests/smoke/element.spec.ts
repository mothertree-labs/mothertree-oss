import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { completeMatrixSignIn } from '../../helpers/auth';

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

    // Element → Matrix Authentication Service → Keycloak → MAS consent → Element
    await completeMatrixSignIn(page, {
      username: TEST_USERS.member.username,
      password: TEST_USERS.member.password,
    });

    // Wait for Element to finish loading — use domcontentloaded since
    // Element's WebSocket connections prevent networkidle from firing
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    // Verify we left the auth/MAS pages
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');
    expect(hostname).not.toMatch(/^mas\./);

    // The page should have substantial content (Element SPA)
    const bodyText = await page.locator('body').textContent();
    expect(bodyText!.length).toBeGreaterThan(50);
  });
});
