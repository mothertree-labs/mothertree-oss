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
// After completing passkey setup in Keycloak, /guest-complete used to redirect
// guests directly to the unauthenticated share URL, which caused Nextcloud to
// show a redundant name prompt.
//
// The fix redirects through Nextcloud's OIDC login flow instead, so the guest
// arrives authenticated and Nextcloud already knows their name.
//
// This test verifies:
// /guest-complete redirects through /login (not directly to /s/{token})
test.describe('Smoke — Guest Complete OIDC Redirect via /guest-complete (Issue #167)', () => {
  test.setTimeout(90_000);

  test('/guest-complete with share redirects through OIDC login, not directly to /s/', async ({
    memberPage,
    context,
  }) => {
    // Step 1: Login to Nextcloud and create an email share to get a real token
    await loginToNextcloud(memberPage);

    const ts = Date.now();
    const testFileName = `${e2ePrefix('oidc')}-redirect-${ts}.txt`;
    const guestEmail = `${e2ePrefix('oidc')}-${ts}@external-test.example`;
    const deleteFile = await uploadTestFile(memberPage, testFileName);

    let shareId: string | undefined;

    try {
      const result = await ocsApiCall(
        memberPage,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4, // TYPE_EMAIL
          shareWith: guestEmail,
        },
      );

      if (result.status !== 200 || result.body?.ocs?.meta?.statuscode !== 200) {
        test.skip(true, 'Share creation failed, skipping OIDC redirect test');
        return;
      }

      shareId = result.body?.ocs?.data?.id;
      const shareToken = result.body?.ocs?.data?.token;
      expect(shareToken, 'Share must include a token').toBeTruthy();

      // Step 2: Visit /guest-complete with the share token in a new unauthenticated context.
      // We block network requests to avoid actually following through to Nextcloud
      // — we only need to verify the redirect URL.
      const unauthContext = await context.browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const guestPage = await unauthContext.newPage();

      try {
        // Intercept the redirect by listening for the response
        const guestCompleteUrl = `${urls.accountPortal}/guest-complete?share=${encodeURIComponent(shareToken!)}`;

        const response = await guestPage.goto(guestCompleteUrl, {
          waitUntil: 'commit',
        });

        // The redirect chain should go through /login?redirect_url= on the files host
        // and NOT directly to /s/{token}
        const finalUrl = guestPage.url();

        // The redirect should point to files host with /login?redirect_url=
        // OR the page should have been redirected through the OIDC flow
        // (ending up on Keycloak login since we're unauthenticated)
        const isDirectShareUrl =
          finalUrl.includes(`/s/${shareToken}`) &&
          !finalUrl.includes('/login');

        expect(
          isDirectShareUrl,
          `/guest-complete must redirect through OIDC login, not directly to the share URL. ` +
            `Got: ${finalUrl}. ` +
            `Expected the redirect to go through /login?redirect_url= on the files host. ` +
            `Direct /s/{token} access shows a redundant name prompt (Issue #167).`,
        ).toBe(false);

        // Verify the URL went through a login flow (either files.*/login or auth.*/realms/)
        const wentThroughLogin =
          finalUrl.includes('/login') || finalUrl.includes('/realms/');
        expect(
          wentThroughLogin,
          `/guest-complete should redirect through login flow. Got: ${finalUrl}`,
        ).toBe(true);
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
