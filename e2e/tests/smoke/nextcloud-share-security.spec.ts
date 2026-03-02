import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { keycloakLogin } from '../../helpers/auth';
import { TEST_USERS } from '../../helpers/test-users';
import { Page } from '@playwright/test';

/**
 * Handle Nextcloud login — same pattern as nextcloud.spec.ts.
 */
async function handleNextcloudLogin(page: Page): Promise<void> {
  if (page.url().includes('auth.')) {
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('networkidle').catch(() => {});
    return;
  }

  const onNativeLogin = page.url().includes('/login') &&
    !page.url().includes('user_oidc') &&
    await page.locator('input[name="password"], #password').isVisible({ timeout: 2_000 }).catch(() => false);

  if (onNativeLogin) {
    const oidcResponse = await page.goto(`${urls.files}/apps/user_oidc/login/1`, { timeout: 30_000 }).catch(() => null);
    if (!oidcResponse) return;
    await page.waitForLoadState('networkidle').catch(() => {});
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }
  }
}

/**
 * Verify Nextcloud share security policies are enforced (Issue #119).
 *
 * These tests use the OCS capabilities endpoint (/ocs/v2.php/cloud/capabilities)
 * which is accessible to any authenticated user and reports the active sharing
 * configuration including sharebymail status and password enforcement.
 */
test.describe('Smoke — Nextcloud Share Security', () => {
  let capabilities: Record<string, any> | null = null;

  /**
   * Fetch capabilities once and reuse across tests.
   */
  async function getCapabilities(page: Page): Promise<Record<string, any> | null> {
    if (capabilities) return capabilities;

    // Navigate to Nextcloud to establish OIDC session
    await page.goto(urls.files);
    await page.waitForLoadState('networkidle').catch(() => {});
    await handleNextcloudLogin(page);
    await page.waitForLoadState('networkidle').catch(() => {});

    // Fetch capabilities via OCS API (uses the session cookie from OIDC login)
    const response = await page.goto(
      `${urls.files}/ocs/v2.php/cloud/capabilities?format=json`,
      { waitUntil: 'load' }
    );

    if (!response || response.status() >= 400) return null;

    const body = await response.json().catch(() => null);
    capabilities = body?.ocs?.data?.capabilities ?? null;
    return capabilities;
  }

  test('sharebymail is disabled', async ({ memberPage: page }) => {
    const caps = await getCapabilities(page);

    if (!caps) {
      test.skip(true, 'Nextcloud capabilities API not reachable');
      return;
    }

    // When sharebymail is disabled, the files_sharing.sharebymail capability
    // is either absent or has enabled=false
    const shareByMailEnabled = caps?.files_sharing?.sharebymail?.enabled ?? false;

    expect(
      shareByMailEnabled,
      'sharebymail must be DISABLED to prevent unauthenticated public links via email shares (Issue #119). ' +
      'Fix: run "php occ app:disable sharebymail" or redeploy Nextcloud.'
    ).toBe(false);
  });

  test('public link password enforcement is enabled', async ({ memberPage: page }) => {
    const caps = await getCapabilities(page);

    if (!caps) {
      test.skip(true, 'Nextcloud capabilities API not reachable');
      return;
    }

    const publicCaps = caps?.files_sharing?.public;

    if (!publicCaps) {
      test.skip(true, 'Nextcloud sharing capabilities not available');
      return;
    }

    // password.enforced should be true when shareapi_enforce_links_password=yes
    const passwordEnforced = publicCaps?.password?.enforced ?? false;

    expect(
      passwordEnforced,
      'Public link password enforcement must be enabled (shareapi_enforce_links_password=yes). ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_links_password --value=yes" or redeploy Nextcloud.'
    ).toBe(true);
  });

  test('public link expiration is enforced', async ({ memberPage: page }) => {
    const caps = await getCapabilities(page);

    if (!caps) {
      test.skip(true, 'Nextcloud capabilities API not reachable');
      return;
    }

    const expireDate = caps?.files_sharing?.public?.expire_date;

    if (!expireDate) {
      test.skip(true, 'Nextcloud expire_date capabilities not available');
      return;
    }

    // enforced should be true when shareapi_enforce_expire_date=yes
    const expirationEnforced = expireDate?.enforced ?? false;

    expect(
      expirationEnforced,
      'Public link expiration enforcement must be enabled (shareapi_enforce_expire_date=yes). ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_expire_date --value=yes" or redeploy Nextcloud.'
    ).toBe(true);
  });
});
