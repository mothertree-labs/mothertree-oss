/**
 * E2E test: Synapse room invite exercises the Stalwart:588 SMTP relay.
 *
 * Verifies the Synapse → Stalwart:588 SASL wiring installed in PR-2b end-to-end.
 * When a user is invited to a Matrix room while offline, Synapse's email
 * notifier sends them a notification email via the configured SMTP submission
 * endpoint. The test confirms the email lands in the invitee's mailbox.
 *
 * Currently skipped by default because Synapse's `email_notifier_plaintext_interval`
 * defaults to 10 minutes (much longer than a CI budget can tolerate). Two
 * preconditions must hold to enable it:
 *   1. Dev's Synapse config must set `email_notifier_plaintext_interval` low
 *      enough (e.g. 30s) so the notifier fires within the test timeout.
 *   2. Set `E2E_SYNAPSE_ROOM_INVITE_ENABLED=1` to opt in.
 *
 * The spec is structured so the room creation + invite path can be exercised
 * independently of the email assertion — once the config is tuned, flip the
 * gate and the SMTP path becomes the actual assertion.
 */

import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import {
  isImapConfigured,
  waitForEmailBody,
  deleteEmailsBySubject,
} from '../../helpers/imap';

const MATRIX_BASE = urls.element.replace(/\/$/, '');

/**
 * Login to Element once via OIDC and return the Matrix access token from
 * Element's localStorage. The token is needed for server-to-server Client-
 * Server API calls that create rooms and issue invites.
 */
async function getMatrixAccessToken(
  page: import('@playwright/test').Page,
  user: { username: string; password: string },
): Promise<string> {
  await page.goto(MATRIX_BASE);
  if (new URL(page.url()).hostname.startsWith('auth.')) {
    const continueLink = page.getByRole('link', { name: 'Continue' });
    if (await continueLink.isVisible({ timeout: 5_000 }).catch(() => false)) {
      await continueLink.click();
    } else {
      await keycloakLogin(page, user.username, user.password);
    }
  }
  // Element persists the access token in localStorage once the SPA initialises.
  await page.waitForFunction(
    () => !!window.localStorage.getItem('mx_access_token'),
    { timeout: 60_000 },
  );
  const token = await page.evaluate(() => window.localStorage.getItem('mx_access_token'));
  expect(token, 'Matrix access token should be present in Element localStorage').toBeTruthy();
  return token as string;
}

/**
 * Resolve a user's canonical Matrix ID via the /whoami endpoint.
 *
 * Synapse's OIDC user_mapping_provider uses the email address as the
 * localpart template, which Synapse then percent-escapes (e.g. `@` → `=40`)
 * to stay within the Matrix localpart grammar. Rather than replicating the
 * escape rules here, we ask Synapse what MXID was actually assigned.
 */
async function whoami(
  page: import('@playwright/test').Page,
  accessToken: string,
): Promise<string> {
  const res = await page.request.get(`${MATRIX_BASE}/_matrix/client/v3/account/whoami`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  expect(res.ok(), `whoami failed: ${res.status()}`).toBe(true);
  const { user_id } = await res.json();
  expect(user_id, 'whoami should return user_id').toBeTruthy();
  return user_id as string;
}

const enabled = process.env.E2E_SYNAPSE_ROOM_INVITE_ENABLED === '1';

test.describe('Onboarding — Synapse Room Invite (SMTP via Stalwart:588)', () => {
  test.skip(
    !enabled,
    'E2E_SYNAPSE_ROOM_INVITE_ENABLED != 1 — needs Synapse email notifier interval reduced in dev before enabling',
  );
  test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

  test('invited offline user receives Synapse notification email', async ({
    emailTestPage: senderPage,
    emailRecvPage: receiverPage,
  }) => {
    test.setTimeout(300_000); // 5 min: email notifier must fire after throttle window

    const sender = TEST_USERS.emailTest;
    const receiver = TEST_USERS.emailRecv;
    const roomAlias = `E2E Invite ${Date.now()}`;

    let roomId: string | null = null;
    try {
      // Warm receiver session so Synapse has a mapped user to invite, then
      // query /whoami to get the authoritative MXID, then close the page to
      // simulate "offline" for the email notifier.
      const receiverToken = await getMatrixAccessToken(receiverPage, receiver);
      const receiverMxid = await whoami(receiverPage, receiverToken);
      await receiverPage.close();

      const senderToken = await getMatrixAccessToken(senderPage, sender);

      // Create a room and invite the receiver via the Matrix Client-Server API.
      const headers = {
        Authorization: `Bearer ${senderToken}`,
        'Content-Type': 'application/json',
      };
      const createRes = await senderPage.request.post(`${MATRIX_BASE}/_matrix/client/v3/createRoom`, {
        headers,
        data: {
          name: roomAlias,
          preset: 'private_chat',
          invite: [receiverMxid],
        },
      });
      expect(createRes.ok(), `createRoom failed: ${createRes.status()} ${await createRes.text()}`).toBe(true);
      const created = await createRes.json();
      roomId = created.room_id;
      expect(roomId, 'room_id should be returned').toBeTruthy();

      // Send a message that mentions the invitee — a common trigger for the
      // email notifier's unread-mention path.
      const txnId = `e2e-${Date.now()}`;
      const sendRes = await senderPage.request.put(
        `${MATRIX_BASE}/_matrix/client/v3/rooms/${encodeURIComponent(roomId!)}/send/m.room.message/${txnId}`,
        {
          headers,
          data: {
            msgtype: 'm.text',
            body: `${receiver.username}: you've been invited (E2E ${Date.now()})`,
          },
        },
      );
      expect(sendRes.ok(), `send message failed: ${sendRes.status()}`).toBe(true);

      // Poll the receiver's inbox. The email subject is Synapse-controlled;
      // match the notif_from display name from apps/environments/*/synapse.yaml.gotmpl.
      const body = await waitForEmailBody({
        userEmail: receiver.email,
        bodyContains: roomAlias,
        timeoutMs: 240_000,
        pollIntervalMs: 10_000,
      });
      expect(body, 'expected Matrix notification email body').toContain(roomAlias);
    } finally {
      if (isImapConfigured()) {
        await deleteEmailsBySubject({ userEmail: receiver.email, subjectContains: roomAlias });
      }
    }
  });
});
