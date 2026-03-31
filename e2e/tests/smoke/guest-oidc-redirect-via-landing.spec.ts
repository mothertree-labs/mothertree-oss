import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
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
        body: 'E2E guest OIDC redirect test file',
      },
    );
    return resp.status;
  }, fileName);

  expect(uploadStatus, `WebDAV PUT returned HTTP ${uploadStatus}`).toBeLessThan(300);

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

// Regression test for Issue #167: Guest asked for name twice.
//
// This test verifies:
// /guest-landing for set-up users also redirects through /login
test.describe('Smoke — Guest OIDC Redirect via /guest-landing (Issue #167)', () => {
  test.setTimeout(90_000);

  test('/guest-landing with set-up user redirects through OIDC login for shares', async ({
    memberPage,
    context,
  }) => {
    // Step 1: Login to Nextcloud and create an email share
    await loginToNextcloud(memberPage);

    const ts = Date.now();
    const testFileName = `${e2ePrefix('landing-oidc')}-${ts}.txt`;
    const guestEmail = `${e2ePrefix('landing-oidc')}-${ts}@external-test.example`;
    const deleteFile = await uploadTestFile(memberPage, testFileName);

    let shareId: string | undefined;

    try {
      const result = await ocsApiCall(
        memberPage,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4,
          shareWith: guestEmail,
        },
      );

      if (result.status !== 200 || result.body?.ocs?.meta?.statuscode !== 200) {
        test.skip(true, 'Share creation failed, skipping guest-landing OIDC test');
        return;
      }

      shareId = result.body?.ocs?.data?.id;
      const shareToken = result.body?.ocs?.data?.token;
      expect(shareToken, 'Share must include a token').toBeTruthy();

      // Step 2: Wait for guest_bridge to provision the user
      await memberPage.waitForTimeout(3000);

      // Step 3: Verify that guest-landing does NOT redirect directly to /s/{token}
      // (which would indicate Issue #167 is still present).
      // We'll test the behavior at the HTTP level: hit /guest-complete and verify
      // the initial 302 redirect URL goes to /login (not /s/).
      const unauthContext = await context.browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const guestPage = await unauthContext.newPage();

      try {
        // Use page.request to check the redirect without following it
        const response = await unauthContext.request.get(
          `${urls.accountPortal}/guest-complete?share=${encodeURIComponent(shareToken!)}`,
          { maxRedirects: 0 },
        );

        // Should be a 302 redirect
        expect(response.status()).toBe(302);

        const location = response.headers()['location'] || '';

        // The redirect MUST go through /login?redirect_url= on the files host
        expect(
          location,
          `/guest-complete must redirect to files host /login, not directly to /s/. ` +
            `Got Location: ${location}. ` +
            `This is the fix for Issue #167 (guest asked for name twice).`,
        ).toContain('/login?redirect_url=');

        // The redirect_url parameter should contain the share path
        expect(
          location,
          `Redirect URL must include the share path /s/${shareToken}. Got: ${location}`,
        ).toContain(encodeURIComponent(`/s/${shareToken}`));

        // Should NOT be a direct /s/ URL
        expect(
          location.endsWith(`/s/${shareToken}`),
          `Must NOT redirect directly to /s/${shareToken}. Got: ${location}`,
        ).toBe(false);
      } finally {
        await unauthContext.close();
      }
    } finally {
      if (shareId) {
        await ocsApiCall(
          memberPage,
          'DELETE',
          `/apps/files_sharing/api/v1/shares/${shareId}`,
        ).catch(() => {});
      }
      await deleteFile();
    }
  });
});
