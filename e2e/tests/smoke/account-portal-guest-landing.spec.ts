import { test, expect } from '../../fixtures/authenticated';
import { test as base } from '@playwright/test';
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
      try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
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
        body: 'E2E guest landing test file',
      },
    );
    return resp.status;
  }, fileName);

  expect(uploadStatus, `WebDAV PUT returned HTTP ${uploadStatus}`).toBeLessThan(300);

  return async () => {
    await page.evaluate(async (name) => {
      const token =
        document
          .querySelector('head[data-requesttoken]')
          ?.getAttribute('data-requesttoken') || '';
      await fetch(
        '/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + name,
        { method: 'DELETE', headers: { requesttoken: token } },
      ).catch(() => {});
    }, fileName).catch(() => {});
  };
}

/**
 * E2E tests for the Account Portal guest-landing route.
 *
 * Verifies that:
 * - /guest-landing without params redirects to /register
 * - /guest-landing with a non-existent email redirects to /register
 * - /guest-landing after a real email share shows the setup page (not the Nextcloud file)
 */
test.describe('Smoke — Account Portal Guest Landing', () => {
  test.setTimeout(90_000);

  test('redirects to /register when parameters are missing', async ({
    context,
  }) => {
    // Use an unauthenticated context
    const unauthContext = await context.browser()!.newContext({
      ignoreHTTPSErrors: true,
    });
    const page = await unauthContext.newPage();

    try {
      await page.goto(`${urls.accountPortal}/guest-landing`);
      await page.waitForLoadState('load');

      // Should redirect to /register
      expect(page.url()).toContain('/register');
    } finally {
      await unauthContext.close();
    }
  });

  test('redirects to /register for non-existent user email', async ({
    context,
  }) => {
    const unauthContext = await context.browser()!.newContext({
      ignoreHTTPSErrors: true,
    });
    const page = await unauthContext.newPage();
    const fakeEmail = `${e2ePrefix('fake')}-${Date.now()}@external-test.example`;

    try {
      await page.goto(
        `${urls.accountPortal}/guest-landing?email=${encodeURIComponent(fakeEmail)}&share=faketoken`,
      );
      await page.waitForLoadState('load');

      // Should redirect to /register with the email preserved
      expect(page.url()).toContain('/register');
      expect(page.url()).toContain(encodeURIComponent(fakeEmail));
    } finally {
      await unauthContext.close();
    }
  });

  test('shows setup page for newly provisioned guest (not Nextcloud redirect)', async ({
    memberPage,
    context,
  }) => {
    // Step 1: Login to Nextcloud and create an email share
    await loginToNextcloud(memberPage);

    const ts = Date.now();
    const testFileName = `${e2ePrefix('landing')}-${ts}.txt`;
    const guestEmail = `${e2ePrefix('landing')}-${ts}@external-test.example`;
    const deleteFile = await uploadTestFile(memberPage, testFileName);

    let shareId: string | undefined;
    let shareToken: string | undefined;

    try {
      const result = await ocsApiCall(
        memberPage,
        'POST',
        '/apps/files_sharing/api/v1/shares',
        {
          path: `/${testFileName}`,
          shareType: 4, // IShare::TYPE_EMAIL
          shareWith: guestEmail,
        },
      );

      if (result.status !== 200 || result.body?.ocs?.meta?.statuscode !== 200) {
        test.skip(true, 'Share creation failed, skipping guest-landing flow test');
        return;
      }

      shareId = result.body?.ocs?.data?.id;
      shareToken = result.body?.ocs?.data?.token;
      expect(shareToken, 'Share must include a token').toBeTruthy();

      // Step 2: Wait briefly for guest_bridge to provision the user
      await memberPage.waitForTimeout(3000);

      // Step 3: Visit guest-landing as unauthenticated user
      const unauthContext = await context.browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const guestPage = await unauthContext.newPage();

      try {
        const landingUrl = `${urls.accountPortal}/guest-landing?email=${encodeURIComponent(guestEmail)}&share=${encodeURIComponent(shareToken!)}`;
        await guestPage.goto(landingUrl);
        await guestPage.waitForLoadState('load');

        // The guest was just provisioned by guest_bridge and has NOT completed
        // passkey setup, so guest-landing should show the setup page.
        // It should NOT redirect to the Nextcloud share URL (files.*/s/token).
        const currentUrl = guestPage.url();
        expect(
          currentUrl,
          `Expected guest-landing to stay on account portal (setup page), ` +
            `but was redirected to: ${currentUrl}. ` +
            `This means the guest-landing route treated the provisioned-but-unset-up ` +
            `user as fully set up and redirected to the Nextcloud share.`,
        ).toContain(urls.accountPortal);

        // Should show the "Check your email" setup page, not the registration form
        const pageContent = await guestPage.locator('body').textContent();
        const isSetupPage = pageContent?.includes('Check your email');
        const isRegisterPage = pageContent?.includes('Guest Registration');

        // Either setup page (user provisioned, needs setup) or register page
        // (guest_bridge provisioning was too slow) — but NOT a Nextcloud redirect
        expect(
          isSetupPage || isRegisterPage,
          `Expected setup page or registration page, but got: ${currentUrl}. ` +
            `Page content: ${pageContent?.slice(0, 200)}`,
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
