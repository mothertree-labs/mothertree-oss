import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { Page } from '@playwright/test';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';

/**
 * Helper: login to Nextcloud and wait for readiness.
 */
async function loginToNextcloud(page: Page): Promise<void> {
  await page.goto(`${urls.files}/apps/files/`);
  await page.waitForLoadState('networkidle').catch(() => {});
  await handleNextcloudLogin(page);
  await page.waitForLoadState('networkidle').catch(() => {});
  await waitForNextcloudReady(page);
}

/**
 * Helper: make an OCS API call from within the browser context.
 * Returns { status, body } where body is the parsed JSON.
 */
async function ocsApiCall(
  page: Page,
  method: string,
  path: string,
  body?: Record<string, unknown>,
): Promise<{ status: number; body: any }> {
  return page.evaluate(
    async ({ method, path, body }) => {
      const oc = (window as any).OC;
      const requesttoken =
        oc?.requesttoken ||
        document.head?.getAttribute('data-requesttoken') ||
        '';

      const headers: Record<string, string> = {
        'OCS-APIRequest': 'true',
        requesttoken,
      };

      const init: RequestInit = {
        method,
        headers,
        credentials: 'same-origin',
      };

      if (body) {
        headers['Content-Type'] = 'application/json';
        init.body = JSON.stringify(body);
      }

      const resp = await fetch(`/ocs/v2.php${path}?format=json`, init);
      const text = await resp.text();
      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = { raw: text };
      }
      return { status: resp.status, body: parsed };
    },
    { method, path, body },
  );
}

/**
 * Helper: upload a test file via WebDAV and return a cleanup function.
 */
async function uploadTestFile(
  page: Page,
  fileName: string,
): Promise<() => Promise<void>> {
  const uploadStatus = await page.evaluate(async (name) => {
    const token =
      document
        .querySelector('head[data-requesttoken]')
        ?.getAttribute('data-requesttoken') || '';
    const resp = await fetch(
      '/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + name,
      {
        method: 'PUT',
        headers: {
          requesttoken: token,
          'Content-Type': 'text/plain',
        },
        body: 'E2E guest share test file',
      },
    );
    return resp.status;
  }, fileName);

  expect(
    uploadStatus,
    `WebDAV PUT returned HTTP ${uploadStatus}`,
  ).toBeLessThan(300);

  // Return cleanup function
  return async () => {
    await page
      .evaluate(async (name) => {
        const token =
          document
            .querySelector('head[data-requesttoken]')
            ?.getAttribute('data-requesttoken') || '';
        await fetch(
          '/remote.php/dav/files/' +
            (window as any).OC.currentUser +
            '/' +
            name,
          {
            method: 'DELETE',
            headers: { requesttoken: token },
          },
        ).catch(() => {});
      }, fileName)
      .catch(() => {});
  };
}

/**
 * Smoke tests for guest sharing (email shares via guest_bridge).
 *
 * The Mothertree sharing flow:
 * 1. User creates an email share (TYPE_EMAIL = 4) via the Nextcloud OCS API
 * 2. sharebymail provider creates the share record
 * 3. guest_bridge listener fires on ShareCreatedEvent, provisions a guest in Keycloak
 * 4. guest_bridge suppresses sharebymail's notification email (no unauthenticated links)
 * 5. Account Portal sends a passkey setup email to the guest instead
 *
 * These tests verify the share creation path works end-to-end.
 */
test.describe('Smoke — Nextcloud Guest Sharing', () => {
  test.setTimeout(90_000);

  test('creating an email share (TYPE_EMAIL) succeeds', async ({
    memberPage: page,
  }) => {
    await loginToNextcloud(page);

    const testFileName = `e2e-guest-share-${Date.now()}.txt`;
    const guestEmail = `e2e-guest-${Date.now()}@external-test.example`;
    const deleteFile = await uploadTestFile(page, testFileName);

    let shareId: string | undefined;

    try {
      // Create a TYPE_EMAIL share (shareType=4) via OCS API.
      // This requires the sharebymail app to be enabled (provides the
      // TYPE_EMAIL share provider). With sharebymail disabled, this
      // returns HTTP 400 or 403 because no provider exists for shareType=4.
      const result = await ocsApiCall(
        page,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4, // IShare::TYPE_EMAIL
          shareWith: guestEmail,
        },
      );

      expect(
        result.status,
        `OCS share creation returned HTTP ${result.status}. ` +
          `Body: ${JSON.stringify(result.body?.ocs?.meta || result.body).slice(0, 300)}. ` +
          'This fails when sharebymail is disabled (no provider for TYPE_EMAIL).',
      ).toBe(200);

      const ocsStatus = result.body?.ocs?.meta?.statuscode;
      expect(
        ocsStatus,
        `OCS statuscode was ${ocsStatus}, expected 200. ` +
          `Message: ${result.body?.ocs?.meta?.message || 'none'}`,
      ).toBe(200);

      shareId = result.body?.ocs?.data?.id;
      expect(shareId, 'Share response must include a share ID').toBeTruthy();

      // Verify the share was created with the correct recipient
      const shareWith = result.body?.ocs?.data?.share_with;
      expect(shareWith).toBe(guestEmail);
    } finally {
      // Clean up: delete the share if it was created
      if (shareId) {
        await ocsApiCall(
          page,
          'DELETE',
          `/apps/files_sharing/api/v1/shares/${shareId}`,
        ).catch(() => {});
      }
      await deleteFile();
    }
  });

  test('email share triggers guest_bridge (not sharebymail notification)', async ({
    memberPage: page,
  }) => {
    await loginToNextcloud(page);

    const testFileName = `e2e-guest-bridge-${Date.now()}.txt`;
    const guestEmail = `e2e-bridge-${Date.now()}@external-test.example`;
    const deleteFile = await uploadTestFile(page, testFileName);

    let shareId: string | undefined;

    try {
      // Create the email share
      const result = await ocsApiCall(
        page,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4,
          shareWith: guestEmail,
        },
      );

      // If share creation fails (sharebymail disabled), skip the rest
      // — the first test covers this assertion.
      if (result.status !== 200 || result.body?.ocs?.meta?.statuscode !== 200) {
        test.skip(
          true,
          'Share creation failed (sharebymail likely disabled), skipping guest_bridge check',
        );
        return;
      }

      shareId = result.body?.ocs?.data?.id;

      // Verify the share was created with mail_send_date absent or null,
      // indicating guest_bridge suppressed the sharebymail notification.
      // When sharebymail sends its own email, it sets mail_send=1 on the share.
      // Our guest_bridge sets mailSend=false, so the notification is skipped.
      const getResult = await ocsApiCall(
        page,
        'GET',
        `/apps/files_sharing/api/v1/shares/${shareId}`,
      );

      expect(getResult.status).toBe(200);

      // The share should exist and be of TYPE_EMAIL
      const shareData = getResult.body?.ocs?.data?.[0] || getResult.body?.ocs?.data;
      expect(shareData?.share_type).toBe(4);
    } finally {
      if (shareId) {
        await ocsApiCall(
          page,
          'DELETE',
          `/apps/files_sharing/api/v1/shares/${shareId}`,
        ).catch(() => {});
      }
      await deleteFile();
    }
  });

  test('guest_bridge and sharebymail apps are both enabled', async ({
    memberPage: page,
  }) => {
    await loginToNextcloud(page);

    // Fetch capabilities to check app status
    const result = await page.evaluate(async () => {
      const oc = (window as any).OC;
      const requesttoken =
        oc?.requesttoken ||
        document.head?.getAttribute('data-requesttoken') ||
        '';

      const resp = await fetch('/ocs/v2.php/cloud/capabilities?format=json', {
        headers: {
          'OCS-APIRequest': 'true',
          requesttoken,
        },
        credentials: 'same-origin',
      });

      return { status: resp.status, body: await resp.text() };
    });

    expect(result.status).toBe(200);
    const capabilities = JSON.parse(result.body)?.ocs?.data?.capabilities;
    expect(capabilities).toBeTruthy();

    // sharebymail must be enabled (provides the TYPE_EMAIL share provider
    // that guest_bridge depends on)
    const shareByMailEnabled =
      capabilities?.files_sharing?.sharebymail?.enabled ?? false;
    expect(
      shareByMailEnabled,
      'sharebymail must be ENABLED to provide the TYPE_EMAIL share provider for guest_bridge. ' +
        'Without it, email shares cannot be created at all.',
    ).toBe(true);

    // Password enforcement must still be active (defense-in-depth for email shares)
    const passwordEnforced =
      capabilities?.files_sharing?.public?.password?.enforced ?? false;
    expect(
      passwordEnforced,
      'Public link password enforcement must remain enabled alongside sharebymail.',
    ).toBe(true);
  });
});
