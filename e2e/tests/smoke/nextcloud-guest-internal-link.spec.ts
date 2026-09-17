import { randomBytes } from 'crypto';
import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { Page } from '@playwright/test';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';
import { keycloakLogin } from '../../helpers/auth';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import {
  completeGuestSetup,
  deleteUser,
  isKeycloakAdminConfigured,
  KeycloakUser,
  waitForUserByEmail,
} from '../../helpers/keycloak-admin';

/**
 * Guests reaching a file through the links an owner actually shares (Issue #718).
 *
 * The owner's own links — the sidebar "Internal link" and the address bar while
 * editing — point at /f/<fileid> and /apps/files/files/<fileid>. An email share is
 * bound to its token and is never mounted into the recipient's Files, so those
 * links used to dead-end on "not found" even after the guest logged in. The
 * guest_bridge middleware now redirects the recipient to that share's /s/<token>.
 *
 * Covered here, on one real share provisioned through the real guest path:
 *   1. the invite link (/guest-landing), which is the flow that already worked;
 *   2. the address-bar link an owner is most likely to copy;
 *   3. a repeat visit to /f/<fileid> in the same session;
 *   4. a signed-in user who is NOT the recipient, who must not be redirected
 *      (the token would otherwise leak to them).
 */
test.describe.serial('Smoke — Guest internal file links (Issue #718)', () => {
  test.setTimeout(180_000);

  const ts = Date.now();
  const fileName = `${e2ePrefix('ilink')}-${ts}.md`;
  const guestEmail = `${e2ePrefix('ilink')}-${ts}@external-test.example`;
  // Random, not derived from anything published: the guest's address contains ts,
  // and this account is a real, sign-in-capable Keycloak user until afterAll
  // removes it — and that cleanup is best-effort.
  const guestPassword = `${randomBytes(24).toString('base64url')}-Pw1!`;

  let shareId: string | undefined;
  let shareToken: string | undefined;
  let fileId: string | undefined;
  let guestUser: KeycloakUser | undefined;
  let ownerPage: Page;

  test.afterAll(async () => {
    if (ownerPage && shareId) {
      await ocsApiCall(
        ownerPage,
        'DELETE',
        `/apps/files_sharing/api/v1/shares/${shareId}`,
      ).catch(() => {});
    }
    if (ownerPage) {
      await deleteFile(ownerPage, fileName).catch(() => {});
    }
    if (guestUser) {
      await deleteUser(guestUser);
    }
  });

  test('prerequisites: Keycloak admin API is reachable', () => {
    expect(
      isKeycloakAdminConfigured() || !process.env.CI,
      'E2E_KC_REALM and E2E_KC_CLIENT_SECRET must be set in CI — ci-resolve-tenant.sh maps ' +
        'E2E_POOL<n>_KC_REALM / E2E_POOL<n>_KC_CLIENT_SECRET into the shard environment.',
    ).toBeTruthy();
    test.skip(!isKeycloakAdminConfigured(), 'Keycloak admin API not configured locally');
  });

  test('owner email-shares a document, which provisions the guest', async ({
    memberPage,
  }) => {
    test.skip(!isKeycloakAdminConfigured(), 'Keycloak admin API not configured locally');
    ownerPage = memberPage;

    await ownerPage.goto(`${urls.files}/apps/files/`);
    await ownerPage.waitForLoadState('networkidle').catch(() => {});
    await handleNextcloudLogin(ownerPage);
    await waitForNextcloudReady(ownerPage);

    await uploadTestFile(ownerPage, fileName);

    const result = await ocsApiCall(
      ownerPage,
      'POST',
      '/apps/files_sharing/api/v1/shares',
      {
        path: `/${fileName}`,
        shareType: 4, // IShare::TYPE_EMAIL
        shareWith: guestEmail,
        permissions: 3, // read + update — the "can edit" a co-editor is given
      },
    );

    expect(
      result.body?.ocs?.meta?.statuscode,
      `Email share creation failed: ${JSON.stringify(result.body?.ocs?.meta || result.body).slice(0, 300)}`,
    ).toBe(200);

    shareId = result.body?.ocs?.data?.id;
    shareToken = result.body?.ocs?.data?.token;
    fileId = String(result.body?.ocs?.data?.file_source ?? '');
    expect(shareToken, 'Email share must carry a token').toBeTruthy();
    expect(
      fileId,
      'Email share response must carry the file id — it is what the owner-copied link contains',
    ).toMatch(/^\d+$/);

    // guest_bridge calls the account portal, which creates the Keycloak guest.
    const guest = await waitForUserByEmail(guestEmail);
    guestUser = guest;

    // A real guest completes setup by following the invite: passkey plus profile.
    // We take them to the same end state through the admin API so the test can
    // sign in with a password; the passkey pages have their own coverage.
    await completeGuestSetup(guest, {
      firstName: 'E2E',
      lastName: 'Guest',
      password: guestPassword,
    });
  });

  test('the invite link opens the file, authenticated as the guest', async ({ context }) => {
    test.skip(!isKeycloakAdminConfigured(), 'Keycloak admin API not configured locally');
    const guestContext = await context.browser()!.newContext({ ignoreHTTPSErrors: true });
    try {
      const page = await guestContext.newPage();
      await page.goto(
        `${urls.accountPortal}/guest-landing?email=${encodeURIComponent(guestEmail)}` +
          `&share=${encodeURIComponent(shareToken!)}`,
      );
      await signInAsGuest(page, guestEmail, guestPassword);
      await expectSharedFileVisible(page, shareToken!, fileName, guestEmail);
    } finally {
      await guestContext.close();
    }
  });

  test('the link an owner copies from the address bar also opens the file', async ({
    context,
  }) => {
    test.skip(!isKeycloakAdminConfigured(), 'Keycloak admin API not configured locally');
    const guestContext = await context.browser()!.newContext({ ignoreHTTPSErrors: true });
    try {
      const page = await guestContext.newPage();
      // What Nextcloud shows in the address bar while the owner has the file open.
      await page.goto(`${urls.files}/apps/files/files/${fileId}?dir=/&openfile=true`);
      await signInAsGuest(page, guestEmail, guestPassword);
      await expectSharedFileVisible(page, shareToken!, fileName, guestEmail);

      // And again later in the same session, via the sidebar's "Internal link".
      await page.goto(`${urls.files}/f/${fileId}`);
      await page.waitForLoadState('networkidle').catch(() => {});
      expect(
        page.url(),
        'A repeat visit to /f/<fileid> must resolve to the share again — the check runs ' +
          'per request and nothing is persisted on the first visit.',
      ).toContain(`/s/${shareToken}`);
    } finally {
      await guestContext.close();
    }
  });

  test('a signed-in non-recipient is not redirected to the share', async ({ adminPage }) => {
    test.skip(!isKeycloakAdminConfigured(), 'Keycloak admin API not configured locally');
    await adminPage.goto(`${urls.files}/apps/files/`);
    await adminPage.waitForLoadState('networkidle').catch(() => {});
    await handleNextcloudLogin(adminPage);
    await waitForNextcloudReady(adminPage);

    await adminPage.goto(`${urls.files}/f/${fileId}`);
    await adminPage.waitForLoadState('networkidle').catch(() => {});

    expect(
      adminPage.url(),
      'Only the recipient of an email share may be sent to its token. Redirecting anyone ' +
        'else would hand them a working link to a file that was not shared with them.',
    ).not.toContain('/s/');
    expect(adminPage.url()).not.toContain(shareToken!);
  });
});

/** Complete the Keycloak login the guest is sent to, then settle on the target page. */
async function signInAsGuest(page: Page, email: string, password: string): Promise<void> {
  await page.waitForURL((url) => url.hostname.startsWith('auth.'), { timeout: 30_000 });
  await keycloakLogin(page, email, password);
  await page.waitForLoadState('networkidle').catch(() => {});
}

/** The guest is on the share page, signed in as themselves, seeing the file. */
async function expectSharedFileVisible(
  page: Page,
  token: string,
  fileName: string,
  guestEmail: string,
): Promise<void> {
  await page.waitForURL((url) => url.pathname.includes(`/s/${token}`), { timeout: 30_000 });
  await page.waitForLoadState('networkidle').catch(() => {});

  // The public share template exposes no session user, so ask Nextcloud who the
  // page's own cookies belong to: anonymous visitors get HTTP 401 here.
  const session = await page.evaluate(async () => {
    const resp = await fetch('/ocs/v2.php/cloud/user?format=json', {
      headers: { 'OCS-APIRequest': 'true' },
      credentials: 'same-origin',
    });
    if (!resp.ok) return { status: resp.status, id: null as string | null };
    const body = await resp.json().catch(() => null);
    return { status: resp.status, id: body?.ocs?.data?.id ?? null };
  });
  expect(
    (session.id || '').toLowerCase(),
    `The guest must arrive signed in (OCS said HTTP ${session.status}). An anonymous ` +
      'visitor is prompted for a name on the share page instead (Issue #167).',
  ).toBe(guestEmail.toLowerCase());

  await expect(
    page.getByText(fileName, { exact: false }).first(),
    `The share page should show ${fileName}`,
  ).toBeVisible({ timeout: 15_000 });
}

/** Make an OCS API call from within the page's session. */
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
        oc?.requesttoken || document.head?.getAttribute('data-requesttoken') || '';
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

async function uploadTestFile(page: Page, name: string): Promise<void> {
  const status = await page.evaluate(async (fileName) => {
    const token =
      document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
    const resp = await fetch(
      '/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + fileName,
      {
        method: 'PUT',
        headers: { requesttoken: token, 'Content-Type': 'text/markdown' },
        body: '# E2E guest internal link test\n\nShared for co-editing.\n',
      },
    );
    return resp.status;
  }, name);
  expect(status, `WebDAV PUT returned HTTP ${status}`).toBeLessThan(300);
}

async function deleteFile(page: Page, name: string): Promise<void> {
  await page
    .evaluate(async (fileName) => {
      const token =
        document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
      await fetch(
        '/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + fileName,
        { method: 'DELETE', headers: { requesttoken: token } },
      ).catch(() => {});
    }, name)
    .catch(() => {});
}
