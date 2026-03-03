import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { Page } from '@playwright/test';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';

/**
 * Fetch Nextcloud capabilities via the OCS API.
 *
 * Uses page.evaluate(fetch()) inside the browser context — same pattern as
 * e2e/helpers/caldav.ts — to correctly handle Nextcloud's session cookies
 * and CSRF requesttoken. A plain page.goto() to OCS endpoints returns
 * HTTP 412 due to strict cookie / CSRF enforcement.
 *
 * Fails the test (not skips) if the API is not reachable — these are
 * security invariants that must always be verifiable.
 */
async function fetchCapabilities(page: Page): Promise<Record<string, any>> {
  // Navigate to Nextcloud and complete OIDC login
  await page.goto(`${urls.files}/apps/files/`);
  await page.waitForLoadState('networkidle').catch(() => {});
  await handleNextcloudLogin(page);
  await page.waitForLoadState('networkidle').catch(() => {});

  // Wait for Nextcloud app to fully load (retries if in maintenance mode during HPA scale-up)
  await waitForNextcloudReady(page);

  // Fetch capabilities inside the browser context (avoids CSRF 412)
  const result = await page.evaluate(async () => {
    const oc = (window as any).OC;
    const requesttoken = oc?.requesttoken
      || document.head?.getAttribute('data-requesttoken')
      || '';

    const resp = await fetch('/ocs/v2.php/cloud/capabilities?format=json', {
      headers: {
        'OCS-APIRequest': 'true',
        requesttoken,
      },
      credentials: 'same-origin',
    });

    return { status: resp.status, body: await resp.text() };
  });

  expect(
    result.status,
    `Nextcloud capabilities API must be reachable to verify share security policies. Got HTTP ${result.status}.`
  ).toBe(200);

  const parsed = JSON.parse(result.body);
  const capabilities = parsed?.ocs?.data?.capabilities;

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
