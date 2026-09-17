import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { BrowserContext, Page } from '@playwright/test';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';
import { keycloakLogin } from '../../helpers/auth';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';

/**
 * Reaching a file through the links an owner actually shares (Issue #718).
 *
 * The owner's own links — the sidebar "Internal link" and the address bar while
 * editing — point at /f/<fileid> and /apps/files/files/<fileid>. An email share is
 * bound to its token and is never mounted into the recipient's Files, so those
 * links used to dead-end on "not found" even after the recipient signed in. The
 * guest_bridge middleware now redirects the recipient to that share's /s/<token>.
 *
 * The middleware's rule is "uid equals the share's recipient address", which holds
 * for anyone an email share names; it does not special-case guests. So this drives
 * the paths with signed-in test users, which keeps the Keycloak admin API — and its
 * client secret — out of the e2e shards, where it is deliberately not available.
 * That leaves one thing uncovered end to end: that sharing to an EXTERNAL address
 * provisions a Keycloak guest through the account portal. nextcloud-guest-share.spec.ts
 * covers the share side of it (the share is created, guest_bridge suppresses
 * sharebymail's mail, a token is issued) but does not assert the Keycloak account
 * appears; asserting that needs the admin API. Passkey setup is covered by
 * e2e/keycloak-theme/.
 *
 * Covered here, on one real email share:
 *   1. the invite link (/guest-landing), the flow that already worked;
 *   2. the address-bar link an owner is most likely to copy;
 *   3. a repeat visit to /f/<fileid> in the same session;
 *   4. a signed-in user who is NOT the recipient, who must not be redirected
 *      (the token would otherwise leak to them).
 */
test.describe.serial('Smoke — Internal file links for share recipients (Issue #718)', () => {
  test.setTimeout(180_000);

  // The member owns the file. emailTest is the recipient: they have no access of
  // their own, and the calendar specs already sign them into Nextcloud, so this
  // adds no account that did not exist. admin is the bystander for the negative
  // case — pipeline-scoped, so their Nextcloud account is ephemeral.
  //
  // NOT emailRecv: calendar-outbound-invite.spec.ts requires that address to have
  // no Nextcloud account, so that Nextcloud treats it as an external attendee and
  // sends an iMIP email instead of scheduling internally. Signing them in here
  // would break that test for every later pipeline on the leased tenant, and
  // emailRecv is fixed rather than pipeline-scoped, so it would not age out.
  const recipient = TEST_USERS.emailTest;
  const bystander = TEST_USERS.admin;

  const ts = Date.now();
  const fileName = `${e2ePrefix('ilink')}-${ts}.md`;

  let shareToken: string | undefined;
  let fileId: string | undefined;

  test('the owner email-shares a document', async ({ memberPage }) => {
    await signInToNextcloud(memberPage);
    await uploadTestFile(memberPage, fileName);

    const result = await ocsApiCall(
      memberPage,
      'POST',
      '/apps/files_sharing/api/v1/shares',
      {
        path: `/${fileName}`,
        shareType: 4, // IShare::TYPE_EMAIL
        shareWith: recipient.email,
        permissions: 3, // read + update — the "can edit" a co-editor is given
      },
    );

    expect(
      result.body?.ocs?.meta?.statuscode,
      `Email share creation failed: ${JSON.stringify(result.body?.ocs?.meta || result.body).slice(0, 300)}`,
    ).toBe(200);

    shareToken = result.body?.ocs?.data?.token;
    fileId = String(result.body?.ocs?.data?.file_source ?? '');
    expect(shareToken, 'Email share must carry a token').toBeTruthy();
    expect(
      fileId,
      'Email share response must carry the file id — it is what the owner-copied link contains',
    ).toMatch(/^\d+$/);
  });

  test('the invite link opens the file, authenticated as the recipient', async ({
    context,
  }) => {
    const recipientContext = await freshContext(context);
    try {
      const page = await recipientContext.newPage();
      await page.goto(
        `${urls.accountPortal}/guest-landing?email=${encodeURIComponent(recipient.email)}` +
          `&share=${encodeURIComponent(shareToken!)}`,
      );
      await signIn(page, recipient.username, recipient.password);
      await expectSharedFileVisible(page, shareToken!, fileName, recipient.email);
    } finally {
      await recipientContext.close();
    }
  });

  test('the link an owner copies from the address bar also opens the file', async ({
    context,
  }) => {
    const recipientContext = await freshContext(context);
    try {
      const page = await recipientContext.newPage();
      // What Nextcloud shows in the address bar while the owner has the file open.
      await page.goto(`${urls.files}/apps/files/files/${fileId}?dir=/&openfile=true`);
      await signIn(page, recipient.username, recipient.password);
      await expectSharedFileVisible(page, shareToken!, fileName, recipient.email);

      // And again later in the same session, via the sidebar's "Internal link".
      await page.goto(`${urls.files}/f/${fileId}`);
      await page.waitForLoadState('networkidle').catch(() => {});
      expect(
        page.url(),
        'A repeat visit to /f/<fileid> must resolve to the share again — the check runs ' +
          'per request and nothing is persisted on the first visit.',
      ).toContain(`/s/${shareToken}`);
    } finally {
      await recipientContext.close();
    }
  });

  test('a signed-in non-recipient is not redirected to the share', async ({ context }) => {
    const otherContext = await freshContext(context);
    try {
      const page = await otherContext.newPage();
      await page.goto(`${urls.files}/f/${fileId}`);
      await signIn(page, bystander.username, bystander.password);
      await page.waitForLoadState('networkidle').catch(() => {});

      expect(
        page.url(),
        'Only the recipient of an email share may be sent to its token. Redirecting anyone ' +
          'else would hand them a working link to a file that was not shared with them.',
      ).not.toContain('/s/');
      expect(page.url()).not.toContain(shareToken!);
    } finally {
      await otherContext.close();
    }
  });

  // Not afterAll: the fixture's page is closed by the time that runs, so the
  // deletes there were swallowed and the file and its share leaked every run.
  // Deleting the file removes its shares with it.
  test('the owner deletes the shared file', async ({ memberPage }) => {
    await signInToNextcloud(memberPage);
    const status = await deleteFile(memberPage, fileName);
    expect(
      status,
      `Cleanup DELETE of ${fileName} returned HTTP ${status} — the test file and its ` +
        'email share are still on the tenant.',
    ).toBeLessThan(400);
  });
});

async function signInToNextcloud(page: Page): Promise<void> {
  await page.goto(`${urls.files}/apps/files/`);
  await page.waitForLoadState('networkidle').catch(() => {});
  await handleNextcloudLogin(page);
  await waitForNextcloudReady(page);
}

function freshContext(context: BrowserContext): Promise<BrowserContext> {
  return context.browser()!.newContext({ ignoreHTTPSErrors: true });
}

/** Complete the Keycloak login we are sent to, then settle on the target page. */
async function signIn(page: Page, username: string, password: string): Promise<void> {
  await page.waitForURL((url) => url.hostname.startsWith('auth.'), { timeout: 30_000 });
  await keycloakLogin(page, username, password);
  await page.waitForLoadState('networkidle').catch(() => {});
}

/** The recipient is on the share page, signed in as themselves, seeing the file. */
async function expectSharedFileVisible(
  page: Page,
  token: string,
  fileName: string,
  email: string,
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
    `The recipient must arrive signed in (OCS said HTTP ${session.status}). An anonymous ` +
      'visitor is prompted for a name on the share page instead (Issue #167).',
  ).toBe(email.toLowerCase());

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
        body: '# E2E internal link test\n\nShared for co-editing.\n',
      },
    );
    return resp.status;
  }, name);
  expect(status, `WebDAV PUT returned HTTP ${status}`).toBeLessThan(300);
}

async function deleteFile(page: Page, name: string): Promise<number> {
  return page.evaluate(async (fileName) => {
    const token =
      document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
    const resp = await fetch(
      '/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + fileName,
      { method: 'DELETE', headers: { requesttoken: token } },
    );
    return resp.status;
  }, name);
}
