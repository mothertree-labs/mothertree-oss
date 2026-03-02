/**
 * CalDAV API helpers for E2E calendar tests.
 *
 * Uses the browser's native fetch() via page.evaluate() to make CalDAV
 * requests. This correctly handles Nextcloud's session cookies and CSRF
 * (requesttoken), avoiding the 412 "strict cookie" and 401 errors that
 * occur with out-of-browser API requests.
 *
 * IMPORTANT: The page MUST already be navigated to the Nextcloud origin
 * (files.${baseDomain}) and OIDC-authenticated before calling any of
 * these functions.
 */

import { Page } from '@playwright/test';

const CALDAV_PATH = '/remote.php/dav';

/**
 * Get the current Nextcloud user ID from the page.
 * OIDC-provisioned users may have a different Nextcloud user ID than
 * their Keycloak username (e.g. a UUID or email). This extracts the
 * actual ID from OC.currentUser after the page has loaded Nextcloud.
 */
export async function getNextcloudUserId(page: Page): Promise<string> {
  const userId = await page.evaluate(() => {
    const oc = (window as any).OC;
    return (
      oc?.currentUser?.uid ||
      oc?.currentUser ||
      document.head?.getAttribute('data-user') ||
      ''
    );
  });

  if (!userId) {
    throw new Error(
      'Could not determine Nextcloud user ID — page may not be on Nextcloud origin or not fully loaded',
    );
  }

  return userId;
}

interface CalendarEntry {
  href: string;
  ical: string;
  etag: string;
}

/**
 * Execute a CalDAV request inside the browser context.
 * Runs fetch() within the page so session cookies and SameSite enforcement
 * are handled natively by the browser.
 */
async function caldavFetch(
  page: Page,
  path: string,
  method: string,
  body?: string,
  extraHeaders?: Record<string, string>,
): Promise<{ status: number; body: string }> {
  return page.evaluate(
    async ({ path, method, body, extraHeaders }) => {
      const oc = (window as any).OC;
      const requesttoken =
        oc?.requesttoken ||
        document.head?.getAttribute('data-requesttoken') ||
        '';

      const headers: Record<string, string> = {
        requesttoken,
        ...(extraHeaders || {}),
      };

      const resp = await fetch(path, {
        method,
        headers,
        body: body || undefined,
        credentials: 'same-origin',
      });

      return { status: resp.status, body: await resp.text() };
    },
    { path, method, body, extraHeaders },
  );
}

/**
 * CalDAV REPORT to find an event by summary in a user's personal calendar.
 * Returns the raw iCal text of the first matching event, or null.
 */
export async function caldavReport(
  page: Page,
  username: string,
  summary: string,
): Promise<string | null> {
  const entry = await caldavReportEntry(page, username, summary);
  return entry ? entry.ical : null;
}

/**
 * CalDAV REPORT returning full entry (href + ical + etag) for a matching event.
 */
export async function caldavReportEntry(
  page: Page,
  username: string,
  summary: string,
): Promise<CalendarEntry | null> {
  const path = `${CALDAV_PATH}/calendars/${username}/personal/`;

  const result = await caldavFetch(
    page,
    path,
    'REPORT',
    `<?xml version="1.0" encoding="UTF-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag/>
    <c:calendar-data/>
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT"/>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>`,
    {
      'Content-Type': 'application/xml; charset=utf-8',
      Depth: '1',
    },
  );

  if (result.status >= 400) {
    console.warn(
      `CalDAV REPORT failed: HTTP ${result.status} — ${result.body.substring(0, 300)}`,
    );
    return null;
  }

  const entries = parseMultistatus(result.body);
  for (const entry of entries) {
    if (entry.ical.includes(`SUMMARY:${summary}`)) {
      return entry;
    }
  }

  return null;
}

/**
 * Extract PARTSTAT for a given attendee email from iCal text.
 * Returns the PARTSTAT value (e.g. "ACCEPTED", "NEEDS-ACTION") or null.
 */
export function parsePartstat(
  icalText: string,
  attendeeEmail: string,
): string | null {
  // Normalize: iCal can have line folding (CRLF + space)
  const unfolded = icalText.replace(/\r?\n[ \t]/g, '');

  const emailLower = attendeeEmail.toLowerCase();
  const lines = unfolded.split(/\r?\n/);

  for (const line of lines) {
    if (
      line.startsWith('ATTENDEE') &&
      line.toLowerCase().includes(emailLower)
    ) {
      const partstatMatch = /PARTSTAT=([A-Z-]+)/i.exec(line);
      if (partstatMatch) {
        return partstatMatch[1].toUpperCase();
      }
    }
  }

  return null;
}

/**
 * Poll CalDAV until an event with the given summary appears.
 * Returns the iCal text when found.
 */
export async function pollForEvent(
  page: Page,
  username: string,
  summary: string,
  timeoutMs = 180_000,
  intervalMs = 10_000,
): Promise<string> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const ical = await caldavReport(page, username, summary);
    if (ical) {
      return ical;
    }
    await page.waitForTimeout(intervalMs);
  }

  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for CalDAV event "${summary}" ` +
      `in calendar of user "${username}"`,
  );
}

/**
 * Poll CalDAV until the PARTSTAT for a specific attendee matches the expected value.
 * Returns the iCal text when the condition is met.
 */
export async function pollForPartstat(
  page: Page,
  username: string,
  summary: string,
  attendeeEmail: string,
  expectedPartstat: string,
  timeoutMs = 180_000,
  intervalMs = 10_000,
): Promise<string> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const ical = await caldavReport(page, username, summary);
    if (ical) {
      const partstat = parsePartstat(ical, attendeeEmail);
      if (partstat === expectedPartstat.toUpperCase()) {
        return ical;
      }
    }
    await page.waitForTimeout(intervalMs);
  }

  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for PARTSTAT=${expectedPartstat} ` +
      `on attendee "${attendeeEmail}" for event "${summary}" ` +
      `in calendar of user "${username}"`,
  );
}

/**
 * Poll CalDAV until an event with the given summary is gone (deleted).
 */
export async function pollForEventGone(
  page: Page,
  username: string,
  summary: string,
  timeoutMs = 180_000,
  intervalMs = 10_000,
): Promise<void> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const ical = await caldavReport(page, username, summary);
    if (!ical) {
      return;
    }
    await page.waitForTimeout(intervalMs);
  }

  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for CalDAV event "${summary}" ` +
      `to be deleted from calendar of user "${username}"`,
  );
}

/**
 * PUT an iCal event into a user's personal calendar (for seeding test data).
 */
export async function caldavPut(
  page: Page,
  username: string,
  uid: string,
  icalBody: string,
): Promise<void> {
  const path = `${CALDAV_PATH}/calendars/${username}/personal/${uid}.ics`;

  const result = await caldavFetch(page, path, 'PUT', icalBody, {
    'Content-Type': 'text/calendar; charset=utf-8',
  });

  if (result.status >= 400 && result.status !== 201) {
    throw new Error(
      `CalDAV PUT failed for ${uid}: HTTP ${result.status} — ${result.body.substring(0, 200)}`,
    );
  }
}

/**
 * DELETE an event from a user's personal calendar (cleanup).
 * Silently ignores 404 (event already gone).
 */
export async function caldavDelete(
  page: Page,
  username: string,
  uid: string,
): Promise<void> {
  const path = `${CALDAV_PATH}/calendars/${username}/personal/${uid}.ics`;

  const result = await caldavFetch(page, path, 'DELETE');

  if (result.status >= 400 && result.status !== 404) {
    console.warn(
      `CalDAV DELETE warning for ${uid}: HTTP ${result.status} — ${result.body.substring(0, 200)}`,
    );
  }
}

/**
 * GET an event from a user's personal calendar by UID.
 * Returns the iCal text or null if not found.
 */
export async function caldavGet(
  page: Page,
  username: string,
  uid: string,
): Promise<string | null> {
  const path = `${CALDAV_PATH}/calendars/${username}/personal/${uid}.ics`;

  const result = await caldavFetch(page, path, 'GET', undefined, {
    Accept: 'text/calendar',
  });

  if (result.status === 404 || result.status >= 400) {
    return null;
  }

  return result.body;
}

/**
 * Parse a CalDAV multistatus XML response into entries.
 * Handles various namespace prefixes used by Nextcloud.
 */
function parseMultistatus(xml: string): CalendarEntry[] {
  const entries: CalendarEntry[] = [];

  // Match response blocks — handle both prefixed and unprefixed DAV namespace
  const responseRegex =
    /<(?:d:|D:|dav:)?response[^>]*>([\s\S]*?)<\/(?:d:|D:|dav:)?response>/gi;
  let responseMatch;

  while ((responseMatch = responseRegex.exec(xml)) !== null) {
    const block = responseMatch[1];

    // Extract href
    const hrefMatch =
      /<(?:d:|D:|dav:)?href[^>]*>([^<]+)<\/(?:d:|D:|dav:)?href>/i.exec(block);
    const href = hrefMatch ? hrefMatch[1] : '';

    // Extract etag
    const etagMatch =
      /<(?:d:|D:|dav:)?getetag[^>]*>([^<]+)<\/(?:d:|D:|dav:)?getetag>/i.exec(
        block,
      );
    const etag = etagMatch ? etagMatch[1].replace(/"/g, '') : '';

    // Extract calendar-data (various namespace prefixes)
    let ical = '';
    const calDataMatch =
      /<(?:cal:|c:|C:|caldav:)?calendar-data[^>]*>([\s\S]*?)<\/(?:cal:|c:|C:|caldav:)?calendar-data>/i.exec(
        block,
      );
    if (calDataMatch) {
      ical = decodeXmlEntities(calDataMatch[1].trim());
    }

    if (href && ical) {
      entries.push({ href, ical, etag });
    }
  }

  return entries;
}

function decodeXmlEntities(text: string): string {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
}
