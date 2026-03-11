import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { Page } from '@playwright/test';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';
import { e2ePrefix } from '../../helpers/e2e-prefix';

async function loginToNextcloud(page: Page): Promise<void> {
  await page.goto(`${urls.files}/apps/files/`);
  await page.waitForLoadState('networkidle').catch(() => {});
  await handleNextcloudLogin(page);
  await page.waitForLoadState('networkidle').catch(() => {});
  await waitForNextcloudReady(page);
}

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
      const init: RequestInit = { method, headers, credentials: 'same-origin' };
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
        headers: { requesttoken: token, 'Content-Type': 'text/plain' },
        body: 'E2E share existing email test file',
      },
    );
    return resp.status;
  }, fileName);

  expect(uploadStatus, `WebDAV PUT returned HTTP ${uploadStatus}`).toBeLessThan(
    300,
  );

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
          { method: 'DELETE', headers: { requesttoken: token } },
        ).catch(() => {});
      }, fileName)
      .catch(() => {});
  };
}

/**
 * Regression tests for sharing with emails that already exist (Issue #168).
 *
 * When a user's email is known to Nextcloud (they've logged in via OIDC),
 * Nextcloud's sharebymail SearchPlugin skips adding the email to the sharees
 * results, assuming the UserPlugin will handle it. This means:
 * 1. The share dialog doesn't offer the "Email" share option for known users
 * 2. Users can't re-share with previously provisioned guests via email
 *
 * The fix (MailSharePlugin in guest_bridge) ensures the email option is always
 * available, regardless of whether the email belongs to a known user.
 */
test.describe('Smoke — Nextcloud Share With Existing Email', () => {
  test.setTimeout(90_000);

  test('sharees API returns email option for known user email', async ({
    memberPage: page,
  }) => {
    // TODO: Fix for pipeline-scoped users — user_oidc doesn't populate email in
    // Nextcloud's DB on first login, so getByEmail() returns empty.
    // https://github.com/mothertree-labs/mothertree-oss/issues/184
    test.skip(!!process.env.CI, 'Skipped in CI: pipeline-scoped users not found by getByEmail (#184)');

    await loginToNextcloud(page);

    // The member user is now logged into Nextcloud, so their email is known.
    // Search the sharees API for the member's own email.
    const memberEmail = TEST_USERS.member.email;

    const result = await page.evaluate(
      async ({ email }) => {
        const oc = (window as any).OC;
        const requesttoken =
          oc?.requesttoken ||
          document.head?.getAttribute('data-requesttoken') ||
          '';

        const params = new URLSearchParams({
          search: email,
          itemType: 'file',
          'shareType[]': '4', // TYPE_EMAIL
          format: 'json',
        });

        const resp = await fetch(
          `/ocs/v2.php/apps/files_sharing/api/v1/sharees?${params}`,
          {
            headers: {
              'OCS-APIRequest': 'true',
              requesttoken,
            },
            credentials: 'same-origin',
          },
        );

        return { status: resp.status, body: await resp.json() };
      },
      { email: memberEmail },
    );

    expect(result.status).toBe(200);

    // The response should include the email in the exact > emails section.
    // Without the guest_bridge MailSharePlugin fix, this would be empty
    // because sharebymail's SearchPlugin skips emails belonging to known users.
    const exactEmails = result.body?.ocs?.data?.exact?.emails ?? [];
    const emailResults = result.body?.ocs?.data?.emails ?? [];
    const allEmailResults = [...exactEmails, ...emailResults];

    expect(
      allEmailResults.length,
      `Sharees API must return an email option for known user email "${memberEmail}". ` +
        `Got exact.emails=${JSON.stringify(exactEmails)}, emails=${JSON.stringify(emailResults)}. ` +
        'Without the guest_bridge MailSharePlugin, the email option is missing for known users.',
    ).toBeGreaterThan(0);

    // Verify the email result has the correct share type
    const emailEntry = allEmailResults.find(
      (r: any) =>
        r.value?.shareWith === memberEmail &&
        r.value?.shareType === 4, // TYPE_EMAIL
    );
    expect(
      emailEntry,
      `Sharees API must include TYPE_EMAIL (4) entry for "${memberEmail}". ` +
        `Results: ${JSON.stringify(allEmailResults).slice(0, 500)}`,
    ).toBeTruthy();
  });

  test('TYPE_EMAIL share succeeds with previously-shared email (different file)', async ({
    memberPage: page,
  }) => {
    await loginToNextcloud(page);

    const ts = Date.now();
    const fileA = `${e2ePrefix('reshare')}-a-${ts}.txt`;
    const fileB = `${e2ePrefix('reshare')}-b-${ts}.txt`;
    const guestEmail = `${e2ePrefix('reshare')}-${ts}@external-test.example`;

    const deleteFileA = await uploadTestFile(page, fileA);
    const deleteFileB = await uploadTestFile(page, fileB);

    let shareIdA: string | undefined;
    let shareIdB: string | undefined;

    try {
      // Share file A with the email
      const resultA = await ocsApiCall(
        page,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${fileA}`,
          shareType: 4,
          shareWith: guestEmail,
        },
      );

      expect(
        resultA.status,
        `First share creation returned HTTP ${resultA.status}. ` +
          `Body: ${JSON.stringify(resultA.body?.ocs?.meta || resultA.body).slice(0, 300)}`,
      ).toBe(200);
      expect(resultA.body?.ocs?.meta?.statuscode).toBe(200);
      shareIdA = resultA.body?.ocs?.data?.id;

      // Share file B with the SAME email — this is the regression test.
      // Previously this could fail because the email was already "known"
      // after the first share (guest provisioned in Keycloak).
      const resultB = await ocsApiCall(
        page,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${fileB}`,
          shareType: 4,
          shareWith: guestEmail,
        },
      );

      expect(
        resultB.status,
        `Second share (same email, different file) returned HTTP ${resultB.status}. ` +
          `Body: ${JSON.stringify(resultB.body?.ocs?.meta || resultB.body).slice(0, 300)}. ` +
          'Sharing with a previously-used email must work (Issue #168).',
      ).toBe(200);
      expect(
        resultB.body?.ocs?.meta?.statuscode,
        `Second share OCS statuscode was ${resultB.body?.ocs?.meta?.statuscode}. ` +
          `Message: ${resultB.body?.ocs?.meta?.message || 'none'}. ` +
          'TYPE_EMAIL shares must succeed for previously-shared emails.',
      ).toBe(200);
      shareIdB = resultB.body?.ocs?.data?.id;

      // Verify both shares exist
      expect(shareIdA).toBeTruthy();
      expect(shareIdB).toBeTruthy();
      expect(shareIdA).not.toBe(shareIdB);
    } finally {
      if (shareIdA) {
        await ocsApiCall(
          page,
          'DELETE',
          `/apps/files_sharing/api/v1/shares/${shareIdA}`,
        ).catch(() => {});
      }
      if (shareIdB) {
        await ocsApiCall(
          page,
          'DELETE',
          `/apps/files_sharing/api/v1/shares/${shareIdB}`,
        ).catch(() => {});
      }
      await deleteFileA();
      await deleteFileB();
    }
  });

  test('TYPE_EMAIL share creation succeeds for existing Keycloak user email', async ({
    memberPage: page,
  }) => {
    await loginToNextcloud(page);

    // Use the emailTest user's email — they exist in Keycloak (created by E2E setup)
    // but may or may not have logged into Nextcloud.
    const existingUserEmail = TEST_USERS.emailTest.email;
    const testFileName = `e2e-existing-user-share-${Date.now()}.txt`;
    const deleteFile = await uploadTestFile(page, testFileName);

    let shareId: string | undefined;

    try {
      const result = await ocsApiCall(
        page,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4,
          shareWith: existingUserEmail,
        },
      );

      expect(
        result.status,
        `TYPE_EMAIL share with existing user email returned HTTP ${result.status}. ` +
          `Body: ${JSON.stringify(result.body?.ocs?.meta || result.body).slice(0, 300)}. ` +
          'Email shares must succeed even when the email belongs to an existing Keycloak user.',
      ).toBe(200);

      expect(
        result.body?.ocs?.meta?.statuscode,
        `OCS statuscode was ${result.body?.ocs?.meta?.statuscode}. ` +
          `Message: ${result.body?.ocs?.meta?.message || 'none'}. ` +
          'Nextcloud must not reject TYPE_EMAIL shares for existing user emails.',
      ).toBe(200);

      shareId = result.body?.ocs?.data?.id;
      expect(shareId, 'Share response must include a share ID').toBeTruthy();

      const shareWith = result.body?.ocs?.data?.share_with;
      expect(shareWith).toBe(existingUserEmail);
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
});
