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
 * Fetch Nextcloud capabilities via the OCS API.
 * Fails the test (not skips) if the API is not reachable — these are
 * security invariants that must always be verifiable.
 */
async function fetchCapabilities(page: Page): Promise<Record<string, any>> {
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

  expect(
    response?.ok(),
    'Nextcloud capabilities API must be reachable to verify share security policies. ' +
    `Got HTTP ${response?.status() ?? 'no response'}.`
  ).toBe(true);

  const body = await response!.json().catch(() => null);
  const capabilities = body?.ocs?.data?.capabilities;

  expect(
    capabilities,
    'Nextcloud capabilities API returned unexpected format — cannot verify share security policies.'
  ).toBeTruthy();

  return capabilities;
}

/**
 * Verify Nextcloud share security policies are enforced (Issue #119).
 *
 * These are hard failures, not skips — if any of these tests fail, it means
 * unauthenticated share links may be active, which is a security regression.
 */
test.describe('Smoke — Nextcloud Share Security', () => {

  test('sharebymail is disabled', async ({ memberPage: page }) => {
    const caps = await fetchCapabilities(page);

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
    const caps = await fetchCapabilities(page);

    const passwordEnforced = caps?.files_sharing?.public?.password?.enforced ?? false;

    expect(
      passwordEnforced,
      'Public link password enforcement must be enabled (shareapi_enforce_links_password=yes). ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_links_password --value=yes" or redeploy Nextcloud.'
    ).toBe(true);
  });

  test('public link expiration is enforced', async ({ memberPage: page }) => {
    const caps = await fetchCapabilities(page);

    const expirationEnforced = caps?.files_sharing?.public?.expire_date?.enforced ?? false;

    expect(
      expirationEnforced,
      'Public link expiration enforcement must be enabled (shareapi_enforce_expire_date=yes). ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_expire_date --value=yes" or redeploy Nextcloud.'
    ).toBe(true);
  });
});
