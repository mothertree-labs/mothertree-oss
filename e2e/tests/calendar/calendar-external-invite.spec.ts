import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import {
  caldavDelete,
  caldavDeleteByFilename,
  caldavGet,
  caldavPut,
  caldavPutWithFilename,
  getNextcloudUserId,
  parsePartstat,
  pollForEvent,
  pollForEventGone,
  pollForPartstat,
} from '../../helpers/caldav';
import {
  buildRequest,
  buildReply,
  buildCancel,
  buildEvent,
  buildMimeEmail,
  futureDateIcal,
} from '../../helpers/ical-builder';
import { isImapConfigured, appendCalendarEmail } from '../../helpers/imap';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

/**
 * Navigate to Nextcloud calendar and complete OIDC login.
 * Returns the Nextcloud user ID (may differ from Keycloak username).
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

test.describe('Calendar — External Invite via Calendar Automation', () => {
  test.setTimeout(300_000); // 5 minutes

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

  test('incoming external REQUEST creates event in CalDAV', async ({
    emailTestPage,
  }) => {
    const recipient = TEST_USERS.emailTest;
    const timestamp = Date.now();
    const uid = `e2e-ext-req-${timestamp}`;
    const summary = `E2E External Invite ${timestamp}`;
    const externalOrganizer = 'external-org@example.org';
    const dtstart = futureDateIcal(7, 14);
    const dtend = futureDateIcal(7, 15);

    let recipientNcId = '';

    try {
      // Craft iTIP REQUEST iCal
      const icalBody = buildRequest({
        uid,
        summary,
        organizer: externalOrganizer,
        organizerCn: 'External Organizer',
        attendees: [
          { email: recipient.email, partstat: 'NEEDS-ACTION' },
        ],
        dtstart,
        dtend,
      });

      // Wrap in MIME email
      const mimeMessage = buildMimeEmail({
        from: `External Organizer <${externalOrganizer}>`,
        to: recipient.email,
        subject: summary,
        icalBody,
        method: 'REQUEST',
      });

      // Plant the email in recipient's Stalwart INBOX via IMAP
      await appendCalendarEmail({
        userEmail: recipient.email,
        mimeMessage,
      });

      // Navigate recipient to Nextcloud calendar (establishes OIDC session)
      recipientNcId = await loginToCalendar(emailTestPage, recipient);
      console.log(`Nextcloud user ID for recipient: ${recipientNcId}`);

      // Poll CalDAV for the event to appear (calendar-automation polls every 60s)
      const ical = await pollForEvent(
        emailTestPage,
        recipientNcId,
        summary,
        180_000,
      );

      expect(ical).toBeTruthy();

      // Verify the event has the right organizer and PARTSTAT
      expect(ical).toContain(`ORGANIZER`);
      expect(ical.toLowerCase()).toContain(externalOrganizer.toLowerCase());

      const partstat = parsePartstat(ical, recipient.email);
      expect(
        partstat,
        `Expected PARTSTAT=NEEDS-ACTION, got ${partstat}`,
      ).toBe('NEEDS-ACTION');
    } finally {
      if (recipientNcId) {
        await caldavDelete(emailTestPage, recipientNcId, uid).catch((e) =>
          console.warn('Cleanup: failed to delete event:', e.message),
        );
      }
    }
  });

  // Uses emailTest (fixed user with persistent Stalwart principal) as
  // organizer because IMAP master-user auth requires the principal to exist.
  test('incoming external REPLY updates attendee PARTSTAT in organizer CalDAV', async ({
    emailTestPage,
  }) => {
    const organizer = TEST_USERS.emailTest;
    const timestamp = Date.now();
    const uid = `e2e-ext-reply-${timestamp}`;
    const summary = `E2E External Reply ${timestamp}`;
    const externalAttendee = 'external-att@example.org';
    const dtstart = futureDateIcal(8, 10);
    const dtend = futureDateIcal(8, 11);

    let organizerNcId = '';

    try {
      // Navigate organizer to calendar (establishes OIDC session for CalDAV)
      organizerNcId = await loginToCalendar(emailTestPage, organizer);
      console.log(`Nextcloud user ID for organizer: ${organizerNcId}`);

      // Seed event in organizer's calendar via CalDAV PUT
      const seedIcal = buildEvent({
        uid,
        summary,
        organizer: organizer.email,
        attendees: [
          {
            email: externalAttendee,
            partstat: 'NEEDS-ACTION',
            cn: 'External Attendee',
          },
        ],
        dtstart,
        dtend,
      });

      await caldavPut(emailTestPage, organizerNcId, uid, seedIcal);

      // Verify seed exists
      const seeded = await caldavGet(emailTestPage, organizerNcId, uid);
      expect(seeded, 'Seeded event should exist in CalDAV').toBeTruthy();

      // Craft iTIP REPLY — external attendee accepts
      const replyIcal = buildReply({
        uid,
        summary,
        organizer: organizer.email,
        attendee: {
          email: externalAttendee,
          partstat: 'ACCEPTED',
          cn: 'External Attendee',
        },
        dtstart,
        dtend,
      });

      // Wrap in MIME email and plant in organizer's IMAP
      const mimeMessage = buildMimeEmail({
        from: `External Attendee <${externalAttendee}>`,
        to: organizer.email,
        subject: `Re: ${summary}`,
        icalBody: replyIcal,
        method: 'REPLY',
      });

      await appendCalendarEmail({
        userEmail: organizer.email,
        mimeMessage,
      });

      // Poll CalDAV for PARTSTAT to update to ACCEPTED
      const updatedIcal = await pollForPartstat(
        emailTestPage,
        organizerNcId,
        summary,
        externalAttendee,
        'ACCEPTED',
        180_000,
      );

      expect(updatedIcal).toBeTruthy();
    } finally {
      if (organizerNcId) {
        await caldavDelete(emailTestPage, organizerNcId, uid).catch((e) =>
          console.warn('Cleanup: failed to delete event:', e.message),
        );
      }
    }
  });

  test('incoming external CANCEL removes event from CalDAV', async ({
    emailTestPage,
  }) => {
    const recipient = TEST_USERS.emailTest;
    const timestamp = Date.now();
    const uid = `e2e-ext-cancel-${timestamp}`;
    const summary = `E2E External Cancel ${timestamp}`;
    const externalOrganizer = 'external-org@example.org';
    const dtstart = futureDateIcal(9, 16);
    const dtend = futureDateIcal(9, 17);

    // Navigate recipient to calendar (establishes OIDC session for CalDAV)
    const recipientNcId = await loginToCalendar(emailTestPage, recipient);
    console.log(`Nextcloud user ID for recipient: ${recipientNcId}`);

    // Seed event in recipient's calendar via CalDAV PUT
    const seedIcal = buildEvent({
      uid,
      summary,
      organizer: externalOrganizer,
      attendees: [{ email: recipient.email, partstat: 'ACCEPTED' }],
      dtstart,
      dtend,
    });

    await caldavPut(emailTestPage, recipientNcId, uid, seedIcal);

    // Verify seed exists
    const seeded = await caldavGet(emailTestPage, recipientNcId, uid);
    expect(
      seeded,
      'Seeded event should exist in CalDAV before cancel',
    ).toBeTruthy();

    // Craft iTIP CANCEL
    const cancelIcal = buildCancel({
      uid,
      summary,
      organizer: externalOrganizer,
      attendees: [{ email: recipient.email }],
      dtstart,
      dtend,
    });

    // Wrap in MIME email and plant in recipient's IMAP
    const mimeMessage = buildMimeEmail({
      from: `External Organizer <${externalOrganizer}>`,
      to: recipient.email,
      subject: `Cancelled: ${summary}`,
      icalBody: cancelIcal,
      method: 'CANCEL',
    });

    await appendCalendarEmail({
      userEmail: recipient.email,
      mimeMessage,
    });

    // Poll CalDAV until the event is gone (calendar-automation deletes it)
    await pollForEventGone(
      emailTestPage,
      recipientNcId,
      summary,
      180_000,
    );

    // Verify event is really gone
    const afterCancel = await caldavGet(emailTestPage, recipientNcId, uid);
    expect(afterCancel, 'Event should be deleted after CANCEL').toBeNull();
  });

  // Uses emailTest (fixed user with persistent Stalwart principal) as
  // organizer because IMAP master-user auth requires the principal to exist.
  test('REPLY updates PARTSTAT even when CalDAV filename differs from event UID', async ({
    emailTestPage,
  }) => {
    const organizer = TEST_USERS.emailTest;
    const timestamp = Date.now();
    const uid = `e2e-ext-reply-fname-${timestamp}`;
    const summary = `E2E Reply Filename Mismatch ${timestamp}`;
    const externalAttendee = 'external-att@example.org';
    const dtstart = futureDateIcal(8, 10);
    const dtend = futureDateIcal(8, 11);

    // Use a filename that differs from the VEVENT UID, simulating events
    // created via the Nextcloud UI (which generates its own filenames)
    const caldavFilename = `NC-GENERATED-${timestamp}.ics`;

    let organizerNcId = '';

    try {
      organizerNcId = await loginToCalendar(emailTestPage, organizer);
      console.log(`Nextcloud user ID for organizer: ${organizerNcId}`);

      // Seed event with a DIFFERENT filename than the VEVENT UID
      const seedIcal = buildEvent({
        uid,
        summary,
        organizer: organizer.email,
        attendees: [
          {
            email: externalAttendee,
            partstat: 'NEEDS-ACTION',
            cn: 'External Attendee',
          },
        ],
        dtstart,
        dtend,
      });

      await caldavPutWithFilename(
        emailTestPage,
        organizerNcId,
        caldavFilename,
        seedIcal,
      );

      // Verify seed exists via REPORT (not direct GET by UID)
      const seeded = await pollForEvent(
        emailTestPage,
        organizerNcId,
        summary,
        10_000,
      );
      expect(seeded, 'Seeded event should be findable via REPORT').toBeTruthy();

      // Craft iTIP REPLY — external attendee accepts
      const replyIcal = buildReply({
        uid,
        summary,
        organizer: organizer.email,
        attendee: {
          email: externalAttendee,
          partstat: 'ACCEPTED',
          cn: 'External Attendee',
        },
        dtstart,
        dtend,
      });

      const mimeMessage = buildMimeEmail({
        from: `External Attendee <${externalAttendee}>`,
        to: organizer.email,
        subject: `Re: ${summary}`,
        icalBody: replyIcal,
        method: 'REPLY',
      });

      await appendCalendarEmail({
        userEmail: organizer.email,
        mimeMessage,
      });

      // Poll CalDAV for PARTSTAT to update to ACCEPTED
      const updatedIcal = await pollForPartstat(
        emailTestPage,
        organizerNcId,
        summary,
        externalAttendee,
        'ACCEPTED',
        180_000,
      );

      expect(updatedIcal).toBeTruthy();
    } finally {
      if (organizerNcId) {
        await caldavDeleteByFilename(
          emailTestPage,
          organizerNcId,
          caldavFilename,
        ).catch((e) =>
          console.warn('Cleanup: failed to delete event:', e.message),
        );
      }
    }
  });
});
