/**
 * iCal template builder for E2E calendar tests.
 * Constructs well-formed iTIP (RFC 5546) iCal bodies and MIME emails.
 */

interface Attendee {
  email: string;
  cn?: string;
  partstat?: string;
}

/**
 * Build a VCALENDAR iTIP REQUEST — used for new invitations.
 */
export function buildRequest(opts: {
  uid: string;
  summary: string;
  organizer: string;
  organizerCn?: string;
  attendees: Attendee[];
  dtstart: string; // ISO 8601 e.g. "20260301T100000Z"
  dtend: string;
  description?: string;
  sequence?: number;
}): string {
  const attendeeLines = opts.attendees
    .map((a) => {
      const cn = a.cn ? `;CN=${a.cn}` : '';
      const partstat = a.partstat || 'NEEDS-ACTION';
      return `ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=${partstat};RSVP=TRUE${cn}:mailto:${a.email}`;
    })
    .join('\r\n');

  const organizerCn = opts.organizerCn ? `;CN=${opts.organizerCn}` : '';
  const description = opts.description
    ? `DESCRIPTION:${opts.description}\r\n`
    : '';

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Mothertree E2E//EN',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    `UID:${opts.uid}`,
    `DTSTAMP:${formatIcalDate(new Date())}`,
    `DTSTART:${opts.dtstart}`,
    `DTEND:${opts.dtend}`,
    `SUMMARY:${opts.summary}`,
    description ? description.trimEnd() : null,
    `ORGANIZER${organizerCn}:mailto:${opts.organizer}`,
    attendeeLines,
    `SEQUENCE:${opts.sequence ?? 0}`,
    'STATUS:CONFIRMED',
    'END:VEVENT',
    'END:VCALENDAR',
  ]
    .filter((line) => line !== null)
    .join('\r\n');
}

/**
 * Build a VCALENDAR iTIP REPLY — attendee response to an invitation.
 */
export function buildReply(opts: {
  uid: string;
  summary: string;
  organizer: string;
  attendee: Attendee;
  dtstart: string;
  dtend: string;
  sequence?: number;
}): string {
  const cn = opts.attendee.cn ? `;CN=${opts.attendee.cn}` : '';
  const partstat = opts.attendee.partstat || 'ACCEPTED';

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Mothertree E2E//EN',
    'METHOD:REPLY',
    'BEGIN:VEVENT',
    `UID:${opts.uid}`,
    `DTSTAMP:${formatIcalDate(new Date())}`,
    `DTSTART:${opts.dtstart}`,
    `DTEND:${opts.dtend}`,
    `SUMMARY:${opts.summary}`,
    `ORGANIZER:mailto:${opts.organizer}`,
    `ATTENDEE;PARTSTAT=${partstat}${cn}:mailto:${opts.attendee.email}`,
    `SEQUENCE:${opts.sequence ?? 0}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');
}

/**
 * Build a VCALENDAR iTIP CANCEL — organizer cancels an event.
 */
export function buildCancel(opts: {
  uid: string;
  summary: string;
  organizer: string;
  attendees: Attendee[];
  dtstart: string;
  dtend: string;
  sequence?: number;
}): string {
  const attendeeLines = opts.attendees
    .map((a) => {
      const cn = a.cn ? `;CN=${a.cn}` : '';
      return `ATTENDEE${cn}:mailto:${a.email}`;
    })
    .join('\r\n');

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Mothertree E2E//EN',
    'METHOD:CANCEL',
    'BEGIN:VEVENT',
    `UID:${opts.uid}`,
    `DTSTAMP:${formatIcalDate(new Date())}`,
    `DTSTART:${opts.dtstart}`,
    `DTEND:${opts.dtend}`,
    `SUMMARY:${opts.summary}`,
    `ORGANIZER:mailto:${opts.organizer}`,
    attendeeLines,
    `SEQUENCE:${(opts.sequence ?? 0) + 1}`,
    'STATUS:CANCELLED',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');
}

/**
 * Build a full VCALENDAR event (no METHOD) for seeding via CalDAV PUT.
 */
export function buildEvent(opts: {
  uid: string;
  summary: string;
  organizer: string;
  attendees: Attendee[];
  dtstart: string;
  dtend: string;
  sequence?: number;
}): string {
  const attendeeLines = opts.attendees
    .map((a) => {
      const cn = a.cn ? `;CN=${a.cn}` : '';
      const partstat = a.partstat || 'NEEDS-ACTION';
      return `ATTENDEE;PARTSTAT=${partstat}${cn}:mailto:${a.email}`;
    })
    .join('\r\n');

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Mothertree E2E//EN',
    'BEGIN:VEVENT',
    `UID:${opts.uid}`,
    `DTSTAMP:${formatIcalDate(new Date())}`,
    `DTSTART:${opts.dtstart}`,
    `DTEND:${opts.dtend}`,
    `SUMMARY:${opts.summary}`,
    `ORGANIZER:mailto:${opts.organizer}`,
    attendeeLines,
    `SEQUENCE:${opts.sequence ?? 0}`,
    'STATUS:CONFIRMED',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');
}

/**
 * Wrap an iCal body in an RFC 2822 MIME message with a text/calendar part.
 * This is the format that calendar-automation expects to find in IMAP.
 */
export function buildMimeEmail(opts: {
  from: string;
  to: string;
  subject: string;
  icalBody: string;
  method: string; // REQUEST, REPLY, CANCEL
}): string {
  const boundary = `----=_E2E_${Date.now()}_${Math.random().toString(36).slice(2)}`;
  const messageId = `<e2e-${Date.now()}@mothertree-e2e>`;
  const date = new Date().toUTCString();

  return [
    `From: ${opts.from}`,
    `To: ${opts.to}`,
    `Subject: ${opts.subject}`,
    `Date: ${date}`,
    `Message-ID: ${messageId}`,
    `MIME-Version: 1.0`,
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    `Content-Type: text/calendar; charset="UTF-8"; method=${opts.method}`,
    `Content-Transfer-Encoding: 7bit`,
    '',
    opts.icalBody,
    '',
    `--${boundary}--`,
    '',
  ].join('\r\n');
}

/**
 * Format a JS Date as iCal UTC timestamp (e.g. "20260301T100000Z").
 */
export function formatIcalDate(date: Date): string {
  return date
    .toISOString()
    .replace(/[-:]/g, '')
    .replace(/\.\d{3}/, '');
}

/**
 * Get a future date as iCal format, offset by days from now.
 */
export function futureDateIcal(daysFromNow: number, hour = 10): string {
  const d = new Date();
  d.setDate(d.getDate() + daysFromNow);
  d.setUTCHours(hour, 0, 0, 0);
  return formatIcalDate(d);
}
