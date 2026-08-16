import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import {
  isImapConfigured,
  waitForEmailBody,
  deleteEmailsBySubject,
} from '../../helpers/imap';

/**
 * E2E test for the Docs document-invitation email.
 *
 * Regression guard for two production bugs (2026-08-14):
 * 1. The invite link pointed at the ADMIN portal's /guest-landing, which
 *    doesn't exist (404 "Cannot GET /guest-landing") — the route lives on
 *    the ACCOUNT portal. Guarded by asserting the link host and probing it.
 * 2. DJANGO_EMAIL_LOGO_IMG was unset, so the email logo rendered as
 *    src="None". Guarded by asserting the logo src is a real URL that
 *    serves an image.
 *
 * Flow: emailTest (e2e-mailrt) creates a document via the Docs API and
 * invites emailRecv (e2e-mailrcv), who has a Stalwart mailbox but no Docs
 * account, so the backend takes the invitation path (send_invitation_email,
 * which patch_invitation.py rewrites to the account portal guest landing).
 * The test then reads the delivered email over IMAP and verifies both the
 * link and the logo.
 */

/**
 * Decode enough of a raw MIME source to extract URLs: strip quoted-printable
 * soft line breaks, decode =XX hex escapes, and unescape &amp;. This is not
 * a general MIME decoder — it only needs to make href/src URLs contiguous
 * and literal. Applying it to a 7bit part is harmless for URL extraction.
 */
function decodeForUrls(source: string): string {
  return source
    .replace(/=\r?\n/g, '')
    .replace(/=([0-9A-F]{2})/gi, (_, hex: string) =>
      String.fromCharCode(parseInt(hex, 16)),
    )
    .replace(/&amp;/g, '&');
}

test.describe('Docs — Invitation Email', () => {
  test.setTimeout(240_000);

  test('prerequisites: IMAP must be configured', () => {
    expect(
      isImapConfigured(),
      'E2E_STALWART_ADMIN_PASSWORD must be set (required for IMAP access)',
    ).toBeTruthy();
  });

  test('invitation email has a working guest-landing link and logo', async ({
    emailTestPage,
  }) => {
    const inviter = TEST_USERS.emailTest;
    const invitee = TEST_USERS.emailRecv;
    const timestamp = Date.now();
    const docTitle = `E2E Invitation Email ${timestamp}`;
    let docId = '';

    try {
      // ── Phase 1: Login inviter to Docs (OIDC) ───────────────────────────
      // The Docs SPA redirects unauthenticated visitors to Keycloak via
      // client-side JS (FRONTEND_HOMEPAGE_FEATURE_ENABLED=false), so the
      // auth. hop is NOT visible immediately after goto — wait for it.
      // loginToApp() can't be used here: it checks page.url() synchronously.
      await emailTestPage.goto(urls.docs);
      await emailTestPage
        .waitForURL((u) => u.hostname.startsWith('auth.'), { timeout: 20_000 })
        .catch(() => {}); // already authenticated → no redirect
      if (new URL(emailTestPage.url()).hostname.startsWith('auth.')) {
        await keycloakLogin(emailTestPage, inviter.username, inviter.password);
        await emailTestPage.waitForURL((u) => !u.hostname.startsWith('auth.'), {
          timeout: 30_000,
        });
      }

      // Wait until the Django session is actually established. The OIDC
      // code-for-session exchange happens in the SPA's redirect chain, so
      // poll the API rather than trusting page load state.
      await expect
        .poll(
          async () =>
            (
              await emailTestPage.request.get(`${urls.docs}/api/v1.0/users/me/`)
            ).status(),
          {
            message:
              'Docs API never returned 200 for /users/me/ — OIDC login did not complete',
            timeout: 60_000,
          },
        )
        .toBe(200);

      // Django sets the csrftoken cookie on the OIDC callback response
      // (rotate_token during auth.login) — required for API POSTs.
      const cookies = await emailTestPage.context().cookies(urls.docs);
      const csrfToken = cookies.find((c) => c.name === 'csrftoken')?.value;
      expect(
        csrfToken,
        'Expected a csrftoken cookie after logging into Docs — cannot make API POSTs without it',
      ).toBeTruthy();

      const apiHeaders = {
        'X-CSRFToken': csrfToken!,
        // Django CSRF checks Referer/Origin on HTTPS requests
        Referer: `${urls.docs}/`,
        Origin: urls.docs,
      };

      // ── Phase 2: Create a document ──────────────────────────────────────
      const createResp = await emailTestPage.request.post(
        `${urls.docs}/api/v1.0/documents/`,
        { headers: apiHeaders, data: { title: docTitle } },
      );
      expect(
        createResp.status(),
        `Document creation failed: HTTP ${createResp.status()} — ${await createResp.text().catch(() => '')}`,
      ).toBe(201);
      docId = (await createResp.json()).id;
      console.log(`Document created: ${docTitle} (${docId})`);

      // ── Phase 3: Invite emailRecv (no Docs account → invitation email) ──
      const inviteResp = await emailTestPage.request.post(
        `${urls.docs}/api/v1.0/documents/${docId}/invitations/`,
        { headers: apiHeaders, data: { email: invitee.email, role: 'editor' } },
      );
      expect(
        inviteResp.status(),
        `Invitation failed: HTTP ${inviteResp.status()} — ${await inviteResp.text().catch(() => '')}. ` +
          `If the error says the email belongs to a registered user, ${invitee.email} has ` +
          'logged into Docs at some point and can no longer exercise the invitation path.',
      ).toBe(201);
      console.log(`Invitation sent to ${invitee.email}`);

      // ── Phase 4: Read the delivered email over IMAP ─────────────────────
      const rawSource = await waitForEmailBody({
        userEmail: invitee.email,
        subjectContains: docTitle,
        timeoutMs: 120_000,
      });
      const source = decodeForUrls(rawSource);

      // Stalwart encryption-at-rest turns the stored message into an
      // OpenPGP blob — no URLs are extractable from the raw source. This
      // bit pipeline 1831: the unmerged email-encryption experiment had
      // left encryption enabled on the pool tenants' e2e-mailrcv mailbox.
      expect(
        source.includes('multipart/encrypted'),
        `${invitee.email}'s mailbox has Stalwart encryption-at-rest enabled, ` +
          'so email content cannot be inspected. Disable it via the Stalwart ' +
          'API: POST /api/account/crypto {"type":"disabled"} authenticated as ' +
          `${invitee.username}%master.`,
      ).toBe(false);

      // ── Phase 5: Verify the guest-landing link ──────────────────────────
      const linkMatch = source.match(/https:\/\/[^\s"'<>[\]]+\/guest-landing\?[^\s"'<>[\]]+/);
      expect(
        linkMatch,
        'Expected the invitation email to contain a /guest-landing link. ' +
          'Check ACCOUNT_PORTAL_URL in docs-config and patch_invitation.py.',
      ).toBeTruthy();
      const inviteLink = linkMatch![0];
      // Log host+path only — the query string carries the invitee address
      const linkUrl = new URL(inviteLink);
      console.log(`Invite link: ${linkUrl.origin}${linkUrl.pathname}?<redacted>`);

      const expectedHost = new URL(urls.accountPortal).host;
      expect(
        new URL(inviteLink).host,
        `The invite link must point at the ACCOUNT portal (${expectedHost}) — ` +
          'the /guest-landing route does not exist on other portals (regression: 2026-08-14).',
      ).toBe(expectedHost);

      const linkResp = await emailTestPage.request.get(inviteLink, {
        maxRedirects: 0,
      });
      expect(
        linkResp.status(),
        `GET ${inviteLink} returned HTTP ${linkResp.status()} — the invite link is broken. ` +
          'Expected a 2xx/3xx from the account portal guest-landing route.',
      ).toBeLessThan(400);

      // ── Phase 6: Verify the logo ────────────────────────────────────────
      expect(
        source.includes('src="None"'),
        'The email logo rendered as src="None" — DJANGO_EMAIL_LOGO_IMG is unset ' +
          'in docs-config (regression: 2026-08-14).',
      ).toBe(false);

      const logoMatch = source.match(/<img[^>]*alt="Logo email"[^>]*src="([^"]+)"/) ||
        source.match(/<img[^>]*src="([^"]+)"[^>]*alt="Logo email"/);
      expect(
        logoMatch,
        'Expected the invitation email to contain the logo <img alt="Logo email">',
      ).toBeTruthy();
      const logoUrl = logoMatch![1];
      console.log(`Logo URL: ${logoUrl}`);
      expect(logoUrl, 'Logo src must be an absolute https URL').toMatch(/^https:\/\//);

      const logoResp = await emailTestPage.request.get(logoUrl);
      expect(
        logoResp.status(),
        `GET ${logoUrl} returned HTTP ${logoResp.status()} — the email logo does not resolve. ` +
          'Check the docs-email-assets ConfigMap and the frontend volume mount.',
      ).toBe(200);
      expect(
        logoResp.headers()['content-type'] || '',
        'Expected an image content-type for the email logo',
      ).toContain('image/');
    } finally {
      // ── Cleanup: delete the document and the delivered email ────────────
      if (docId) {
        const cookies = await emailTestPage.context().cookies(urls.docs);
        const csrfToken = cookies.find((c) => c.name === 'csrftoken')?.value;
        if (csrfToken) {
          await emailTestPage.request
            .delete(`${urls.docs}/api/v1.0/documents/${docId}/`, {
              headers: {
                'X-CSRFToken': csrfToken,
                Referer: `${urls.docs}/`,
                Origin: urls.docs,
              },
            })
            .catch(() => {});
        }
      }
      await deleteEmailsBySubject({
        userEmail: invitee.email,
        subjectContains: docTitle,
      }).catch(() => {});
    }
  });
});
