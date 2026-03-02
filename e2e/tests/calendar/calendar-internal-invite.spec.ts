import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import {
  caldavReport,
  caldavReportEntry,
  getNextcloudUserId,
  parsePartstat,
  pollForPartstat,
  caldavDelete,
  caldavPut,
  pollForEvent,
} from '../../helpers/caldav';
import { buildEvent, futureDateIcal } from '../../helpers/ical-builder';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

/**
 * Navigate to Nextcloud calendar and complete OIDC login.
 * Returns the Nextcloud user ID (which may differ from the Keycloak username
 * for OIDC-provisioned users).
 *
 * Nextcloud with allow_multiple_user_backends=1 shows its own login page
 * instead of auto-redirecting to Keycloak. We handle this by navigating
 * directly to the OIDC login endpoint when the page lands on the
 * Nextcloud login form.
 */
async function loginToCalendar(
  page: import('@playwright/test').Page,
  user: { username: string; password: string },
): Promise<string> {
  // Navigate directly to the OIDC login endpoint with a redirect to calendar.
  // This bypasses the Nextcloud native login page entirely.
  const redirectUrl = encodeURIComponent('/apps/calendar');
  await page.goto(`${urls.files}/apps/user_oidc/login/1?redirectUrl=${redirectUrl}`);
  await page.waitForLoadState('networkidle').catch(() => {});

  if (page.url().includes('auth.')) {
    await keycloakLogin(page, user.username, user.password);
  }

  await page.waitForLoadState('networkidle').catch(() => {});
  await page.waitForTimeout(3_000);

  return getNextcloudUserId(page);
}

test.describe('Calendar — Internal Invite Round-Trip', () => {
  test.setTimeout(300_000); // 5 minutes

  test('prerequisites: calendar must be enabled', () => {
    expect(
      config.calendarEnabled,
      'Set calendarEnabled: true in e2e.config.json',
    ).toBeTruthy();
  });

  test('organizer creates event with attendee, recipient sees it via CalDAV scheduling', async ({
    memberPage,
    emailTestPage,
  }) => {
    const sender = TEST_USERS.member;
    const recipient = TEST_USERS.emailTest;
    const timestamp = Date.now();
    const uid = `e2e-internal-${timestamp}`;
    const eventTitle = `E2E Internal Invite ${timestamp}`;
    const dtstart = futureDateIcal(5, 14);
    const dtend = futureDateIcal(5, 15);

    // Track Nextcloud user IDs (may differ from Keycloak usernames)
    let senderNcId = '';
    let recipientNcId = '';

    try {
      // ── Phase 1: Establish OIDC sessions ──────────────────────────────

      senderNcId = await loginToCalendar(memberPage, sender);
      recipientNcId = await loginToCalendar(emailTestPage, recipient);

      console.log(`Nextcloud user IDs — sender: ${senderNcId}, recipient: ${recipientNcId}`);

      // ── Phase 2: Sender creates event with attendee via CalDAV PUT ────

      const eventIcal = buildEvent({
        uid,
        summary: eventTitle,
        organizer: sender.email,
        attendees: [
          { email: recipient.email, partstat: 'NEEDS-ACTION' },
        ],
        dtstart,
        dtend,
      });

      await caldavPut(memberPage, senderNcId, uid, eventIcal);

      // Verify the event was created in the sender's calendar
      const senderEvent = await caldavReport(
        memberPage,
        senderNcId,
        eventTitle,
      );
      expect(
        senderEvent,
        'Event should exist in sender calendar after PUT',
      ).toBeTruthy();

      // ── Phase 3: Verify invite reaches recipient via CalDAV ───────────

      const recipientIcal = await pollForEvent(
        emailTestPage,
        recipientNcId,
        eventTitle,
        180_000,
      );

      expect(recipientIcal).toBeTruthy();

      const partstat = parsePartstat(recipientIcal, recipient.email);
      expect(
        partstat,
        `Expected PARTSTAT=NEEDS-ACTION for recipient, got ${partstat}`,
      ).toBe('NEEDS-ACTION');

      // ── Phase 4: Recipient accepts via CalDAV ─────────────────────────

      const recipientEntry = await caldavReportEntry(
        emailTestPage,
        recipientNcId,
        eventTitle,
      );
      expect(
        recipientEntry,
        'Recipient event entry should exist for acceptance',
      ).toBeTruthy();

      // Modify PARTSTAT to ACCEPTED and PUT back
      const acceptedIcal = recipientEntry!.ical.replace(
        new RegExp(
          `(ATTENDEE[^:]*PARTSTAT=)NEEDS-ACTION([^:]*:mailto:${recipient.email.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`,
          'i',
        ),
        '$1ACCEPTED$2',
      );

      // PUT back to the same resource path (href from REPORT).
      // No If-Match header — the etag from REPORT is stale because
      // Nextcloud's scheduling plugin modifies the event after delivery.
      const resourcePath = recipientEntry!.href;
      await emailTestPage.evaluate(
        async ({ resourcePath, acceptedIcal }) => {
          const oc = (window as any).OC;
          const requesttoken =
            oc?.requesttoken ||
            document.head?.getAttribute('data-requesttoken') ||
            '';

          const resp = await fetch(resourcePath, {
            method: 'PUT',
            headers: {
              requesttoken,
              'Content-Type': 'text/calendar; charset=utf-8',
            },
            body: acceptedIcal,
            credentials: 'same-origin',
          });

          if (resp.status >= 400) {
            const body = await resp.text();
            throw new Error(
              `CalDAV PUT (accept) failed: HTTP ${resp.status} — ${body.substring(0, 200)}`,
            );
          }
        },
        { resourcePath, acceptedIcal },
      );

      // ── Phase 5: Verify sender sees acceptance ────────────────────────

      const updatedIcal = await pollForPartstat(
        memberPage,
        senderNcId,
        eventTitle,
        recipient.email,
        'ACCEPTED',
        180_000,
      );

      expect(updatedIcal).toBeTruthy();
      const finalPartstat = parsePartstat(updatedIcal, recipient.email);
      expect(finalPartstat).toBe('ACCEPTED');
    } finally {
      // ── Cleanup: Delete events from both calendars ────────────────────
      if (senderNcId) {
        await caldavDelete(memberPage, senderNcId, uid).catch((e) =>
          console.warn('Cleanup: failed to delete sender event:', e.message),
        );
      }
      if (recipientNcId) {
        await caldavDelete(emailTestPage, recipientNcId, uid).catch((e) =>
          console.warn(
            'Cleanup: failed to delete recipient event:',
            e.message,
          ),
        );
      }
    }
  });
});
