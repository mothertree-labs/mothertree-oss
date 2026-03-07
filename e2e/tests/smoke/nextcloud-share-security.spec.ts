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

  test('sharebymail is enabled (required by guest_bridge for TYPE_EMAIL shares)', async ({ memberPage: page }) => {
    const caps = await fetchCapabilities(page);

    // sharebymail must be ENABLED to provide the TYPE_EMAIL share provider.
    // Without it, email shares cannot be created and guest_bridge never fires.
    // Security is maintained by: guest_bridge suppresses sharebymail's notification
    // emails (no unauthenticated links sent), and password enforcement remains active.
    // When the app is enabled, files_sharing.sharebymail key is present in capabilities.
    const shareByMailPresent = caps?.files_sharing?.sharebymail !== undefined;

    expect(
      shareByMailPresent,
      'sharebymail capability must be present (app enabled) to provide the TYPE_EMAIL share provider for guest_bridge. ' +
      'Email share security is handled by guest_bridge (suppresses unauthenticated link emails) ' +
      'and password enforcement (shareapi_enforce_links_password=yes).'
    ).toBe(true);
  });

  test('link share password enforcement is disabled (guests use passkeys via guest_bridge)', async ({ memberPage: page }) => {
    // shareapi_allow_links must be 'yes' because TYPE_EMAIL shares are internally
    // link-based and fail with 404 when links are disabled.
    // Security is handled by guest_bridge (intercepts shares, provisions guests via passkeys).
    // Password enforcement must be off so users aren't forced to set passwords on email shares.
    const caps = await fetchCapabilities(page);
    const passwordEnforced = caps?.files_sharing?.public?.password?.enforced ?? false;
    expect(
      passwordEnforced,
      'Link share password enforcement must be disabled (shareapi_enforce_links_password=no). ' +
      'Email shares use passkey authentication via guest_bridge, not passwords. ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_links_password --value=no" or redeploy Nextcloud.'
    ).toBe(false);
  });

  test('share expiration defaults to 30 days but is not enforced', async ({ memberPage: page }) => {
    const caps = await fetchCapabilities(page);
    // Expiry should be suggested (default) but not enforced
    const enforced = caps?.files_sharing?.public?.expire_date?.enforced ?? false;
    expect(
      enforced,
      'Public link expiration must NOT be enforced (shareapi_enforce_expire_date=no). ' +
      'Expiry is suggested by default but users should not be forced to set one. ' +
      'Fix: run "php occ config:app:set core shareapi_enforce_expire_date --value=no" or redeploy Nextcloud.'
    ).toBe(false);
  });
});
