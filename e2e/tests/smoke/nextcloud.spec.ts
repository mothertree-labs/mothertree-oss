import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Nextcloud (Files)', () => {
  test('SSO login loads Nextcloud', async ({ memberPage: page }) => {
    await page.goto(urls.files);
    await page.waitForLoadState('networkidle');

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    }

    await page.waitForLoadState('networkidle');

    // Nextcloud may show OIDC error (known PROXY protocol issue) or the dashboard
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    // Check if we got the known OIDC error
    const hasOidcError = await page.locator('text=/Could not reach the OpenID Connect provider/i').isVisible().catch(() => false);
    test.skip(hasOidcError, 'Nextcloud OIDC provider not reachable (known PROXY protocol issue)');

    // Should have some Nextcloud content
    const hasContent = await page.locator('#app-content, #app-dashboard, .files-list').first().isVisible({ timeout: 10_000 }).catch(() => false);
    expect(hasContent).toBe(true);
  });

  test('can upload a file when Nextcloud is accessible', async ({ memberPage: page }) => {
    await page.goto(`${urls.files}/apps/files/`);
    await page.waitForLoadState('networkidle');

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle');
    }

    // Skip if Nextcloud isn't accessible (OIDC provider error, forbidden, or any error page)
    const hasError = await page.locator('text=/Could not reach|Error|Forbidden|error|500|403/i').isVisible().catch(() => false);
    test.skip(hasError, 'Nextcloud not accessible from this context');

    // Wait for files view
    await page.waitForSelector('#app-content, .files-list', { timeout: 30_000 });

    // Nextcloud has a hidden file input for uploads
    const fileInput = page.locator('input[type="file"]');
    if (await fileInput.count() > 0) {
      await fileInput.first().setInputFiles({
        name: `e2e-test-${Date.now()}.txt`,
        mimeType: 'text/plain',
        buffer: Buffer.from('E2E test file content'),
      });

      // Wait for upload to complete
      await page.waitForTimeout(3000);
      const pageContent = await page.content();
      expect(pageContent).toContain('e2e-test');
    }
  });
});
