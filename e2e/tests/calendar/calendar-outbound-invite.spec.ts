import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import {
  caldavDelete,
  caldavPut,
  getNextcloudUserId,
} from '../../helpers/caldav';
import { buildEvent, futureDateIcal } from '../../helpers/ical-builder';
import { isImapConfigured, countInboxBySubject, deleteEmailsBySubject } from '../../helpers/imap';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

/**
 * Navigate to Nextcloud calendar and complete OIDC login.
 * Returns the Nextcloud user ID.
 */
async function loginToCalendar(
  page: import('@playwright/test').Page,
  user: { username: string; password: string },
): Promise<string> {
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

test.describe('Calendar — Outbound Invitation Email', () => {
  test.setTimeout(180_000); // 3 minutes

  test('prerequisites: calendar and IMAP must be configured', () => {
    expect(
      config.calendarEnabled,
      'Set calendarEnabled: true in e2e.config.json',
    ).toBeTruthy();
    expect(
      isImapConfigured(),
      'E2E_STALWART_ADMIN_PASSWORD must be set (required for IMAP access)',
    ).toBeTruthy();
  });

  // This test verifies the outbound SMTP path for calendar invitations:
  //   Nextcloud IMipPlugin → Postfix → Stalwart → attendee inbox
  //
  // Uses emailTest as organizer (logged into Nextcloud) and emailRecv as
  // attendee. emailRecv should NOT be a Nextcloud user (they only use
  // Roundcube in the email roundtrip test), so Nextcloud treats them as
  // an external attendee and sends the invitation via IMipPlugin + SMTP
  // rather than internal CalDAV scheduling.
  //
  // This is the exact path that broke in production when SMTP env vars
  // were missing from the Nextcloud deployment, causing it to fall back
  // to 127.0.0.1:25 (connection refused).
  test('creating event with external attendee sends invitation email via SMTP', async ({
    emailTestPage,
  }) => {
    const organizer = TEST_USERS.emailTest;
    const attendee = TEST_USERS.emailRecv;
    const timestamp = Date.now();
    const uid = `e2e-outbound-${timestamp}`;
    const eventTitle = `E2E Outbound Invite ${timestamp}`;
    const dtstart = futureDateIcal(6, 14);
    const dtend = futureDateIcal(6, 15);

    let organizerNcId = '';

    try {
      // ── Phase 1: Login organizer to Nextcloud calendar ──────────────────

      organizerNcId = await loginToCalendar(emailTestPage, organizer);
      console.log(`Nextcloud user ID for organizer: ${organizerNcId}`);

      // ── Phase 2: Record baseline inbox count ───────────────────────────

      const beforeCount = await countInboxBySubject({
        userEmail: attendee.email,
        subjectContains: eventTitle,
      });

      // ── Phase 3: Create event with attendee via CalDAV PUT ─────────────

      const eventIcal = buildEvent({
        uid,
        summary: eventTitle,
        organizer: organizer.email,
        attendees: [
          { email: attendee.email, partstat: 'NEEDS-ACTION' },
        ],
        dtstart,
        dtend,
      });

      await caldavPut(emailTestPage, organizerNcId, uid, eventIcal);
      console.log(`Event created: ${eventTitle} (attendee: ${attendee.email})`);

      // ── Phase 4: Poll attendee's IMAP inbox for invitation email ───────

      const maxWait = 120_000;
      const pollInterval = 10_000;
      let found = false;
      const start = Date.now();

      while (Date.now() - start < maxWait) {
        const count = await countInboxBySubject({
          userEmail: attendee.email,
          subjectContains: eventTitle,
        });

        if (count > beforeCount) {
          found = true;
          console.log(
            `Invitation email delivered to ${attendee.email} after ${Math.round((Date.now() - start) / 1000)}s`,
          );
          break;
        }

        await new Promise((r) => setTimeout(r, pollInterval));
      }

      expect(
        found,
        `Expected invitation email for "${eventTitle}" to appear in ` +
          `${attendee.email}'s inbox within ${maxWait / 1000}s. ` +
          `This verifies: Nextcloud IMipPlugin → Postfix → Stalwart.`,
      ).toBe(true);
    } finally {
      // ── Cleanup: Delete event from organizer's calendar ────────────────
      if (organizerNcId) {
        await caldavDelete(emailTestPage, organizerNcId, uid).catch((e) =>
          console.warn('Cleanup: failed to delete event:', e.message),
        );
      }
      // ── Cleanup: Delete invitation email from attendee's inbox ─────────
      if (isImapConfigured()) {
        const deleted = await deleteEmailsBySubject({ userEmail: attendee.email, subjectContains: eventTitle });
        if (deleted > 0) console.log(`  [cleanup] Deleted ${deleted} invitation email(s) from ${attendee.email}`);
      }
    }
  });
});
