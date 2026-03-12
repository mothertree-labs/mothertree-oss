'use strict';

/**
 * Calendar Automation Service
 *
 * Monitors user IMAP inboxes for iTIP calendar messages (REQUEST, REPLY, CANCEL)
 * and automatically creates/updates/cancels events in Nextcloud CalDAV.
 *
 * Architecture:
 *   - Polls Stalwart IMAP for messages with text/calendar MIME parts
 *   - Uses Stalwart admin API to enumerate users
 *   - Uses CalDAV (Nextcloud) to manage calendar events
 *   - Marks processed messages with $CalendarProcessed IMAP flag
 *   - Exposes /healthz and /metrics endpoints for K8s probes
 *
 * Environment variables:
 *   IMAP_HOST            - Stalwart IMAP hostname (cluster-internal)
 *   IMAP_PORT            - Stalwart IMAP port (default: 993, IMAPS with master-user auth)
 *   STALWART_API_URL     - Stalwart management API URL (e.g., http://stalwart:8080)
 *   STALWART_ADMIN_PASSWORD - Admin password for Stalwart API and IMAP
 *   CALDAV_BASE_URL      - Nextcloud CalDAV base URL (e.g., https://files.dev.example.com/remote.php/dav)
 *   CALDAV_ADMIN_USER    - Nextcloud admin username for CalDAV access
 *   CALDAV_ADMIN_PASSWORD - Nextcloud admin password for CalDAV access
 *   POLL_INTERVAL_SECONDS - Polling interval in seconds (default: 60)
 *   HEALTH_PORT          - Health check HTTP port (default: 8080)
 *   LOG_LEVEL            - Logging level: debug, info, warn, error (default: info)
 */

const http = require('node:http');
const fs = require('node:fs');
const { ImapFlow } = require('imapflow');
const ICAL = require('ical.js');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const config = {
  imap: {
    host: requiredEnv('IMAP_HOST'),
    port: parseInt(process.env.IMAP_PORT || '993', 10),
    secure: true,
    // TLS options for cluster-internal connections (cert is for public hostname)
    tls: { rejectUnauthorized: false },
  },
  stalwart: {
    apiUrl: requiredEnv('STALWART_API_URL'),
    adminPassword: requiredEnv('STALWART_ADMIN_PASSWORD'),
  },
  caldav: {
    baseUrl: requiredEnv('CALDAV_BASE_URL'),
    adminUser: process.env.CALDAV_ADMIN_USER || '',
    adminPassword: process.env.CALDAV_ADMIN_PASSWORD || '',
    // Per-user app passwords for CalDAV (Nextcloud requires per-user auth)
    tokenFile: process.env.CALDAV_TOKEN_FILE || '/app/caldav-tokens.json',
  },
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL_SECONDS || '60', 10) * 1000,
  healthPort: parseInt(process.env.HEALTH_PORT || '8080', 10),
  logLevel: process.env.LOG_LEVEL || 'info',
};

// ---------------------------------------------------------------------------
// Retry and dead-letter constants
// ---------------------------------------------------------------------------

const RETRY_BASE_DELAY_MS = 60_000;       // 1 poll cycle
const RETRY_MAX_DELAY_MS = 3_600_000;     // 1 hour cap
const MAX_RETRIES = 5;                     // dead-letter after 5 failures
const DEAD_LETTER_FOLDER = 'INBOX/iTIP-Failed';
const RETRY_PRUNE_INTERVAL = 100;          // prune stale entries every N cycles
const RETRY_STALE_MS = 24 * 60 * 60 * 1000; // 24h

// Key: "${stalwartName}:${uid}", Value: { retries, nextRetryAfter, lastError }
const retryTracker = new Map();

// Key: stalwartName, Value: { consecutiveFullFailures, nextRetryAfter }
const userBackoff = new Map();

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`[FATAL] Required environment variable ${name} is not set`);
    process.exit(1);
  }
  return value;
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };
const currentLogLevel = LOG_LEVELS[config.logLevel] ?? LOG_LEVELS.info;

function log(level, message, extra) {
  if (LOG_LEVELS[level] < currentLogLevel) return;
  const entry = {
    ts: new Date().toISOString(),
    level,
    msg: message,
    ...extra,
  };
  const stream = level === 'error' ? process.stderr : process.stdout;
  stream.write(JSON.stringify(entry) + '\n');
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

const metrics = {
  pollCycles: 0,
  messagesProcessed: 0,
  eventsCreated: 0,
  eventsUpdated: 0,
  eventsCancelled: 0,
  errors: 0,
  lastPollTime: null,
  lastPollDurationMs: 0,
  usersScanned: 0,
  messagesDeadLettered: 0,
  messagesSkippedBackoff: 0,
  usersSkippedBackoff: 0,
  retryTrackerSize: 0,
  healthy: true,
};

// ---------------------------------------------------------------------------
// Health check HTTP server
// ---------------------------------------------------------------------------

function startHealthServer() {
  const server = http.createServer((req, res) => {
    if (req.url === '/healthz') {
      const status = metrics.healthy ? 200 : 503;
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: metrics.healthy ? 'ok' : 'unhealthy' }));
    } else if (req.url === '/metrics') {
      metrics.retryTrackerSize = retryTracker.size;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(metrics, null, 2));
    } else {
      res.writeHead(404);
      res.end('Not Found');
    }
  });

  server.listen(config.healthPort, () => {
    log('info', `Health server listening on port ${config.healthPort}`);
  });

  return server;
}

// ---------------------------------------------------------------------------
// Stalwart user enumeration
// ---------------------------------------------------------------------------

/**
 * List all user accounts from Stalwart admin API.
 * Returns an array of email addresses (usernames).
 */
async function listStalwartUsers() {
  const auth = Buffer.from(`admin:${config.stalwart.adminPassword}`).toString('base64');

  // List all principals of type "individual" (user accounts)
  const url = `${config.stalwart.apiUrl}/api/principal?types=individual&limit=0`;
  const resp = await fetch(url, {
    headers: { Authorization: `Basic ${auth}` },
  });

  if (!resp.ok) {
    throw new Error(`Stalwart API error: ${resp.status} ${resp.statusText}`);
  }

  const body = await resp.json();

  // API returns { data: { items: [...], total: N } }
  // Each item is { name, emails, type, ... }
  // Return objects with both name (for IMAP master-user auth) and email (for CalDAV)
  let items = [];
  if (body.data && body.data.items) {
    items = body.data.items;
  } else if (Array.isArray(body.data)) {
    items = body.data;
  } else {
    log('warn', 'Unexpected Stalwart API response format', { body });
    return [];
  }

  // Extract user info: name (Stalwart principal name) and primary email
  return items
    .filter((u) => u.emails && u.emails.length > 0)
    .map((u) => ({
      name: u.name,
      email: u.emails[0],
    }));
}

// ---------------------------------------------------------------------------
// IMAP operations
// ---------------------------------------------------------------------------

/**
 * Connect to IMAP as admin on behalf of a user.
 * Stalwart supports master-user authentication: "name%master" with admin password.
 * The name must be the Stalwart principal name (not email), e.g. "e2e-member" not "e2e-member@domain".
 */
function createImapClient(stalwartName) {
  return new ImapFlow({
    host: config.imap.host,
    port: config.imap.port,
    secure: config.imap.secure,
    auth: {
      user: `${stalwartName}%master`,
      pass: config.stalwart.adminPassword,
    },
    tls: config.imap.tls,
    logger: false, // Suppress imapflow internal logging
  });
}

/**
 * Scan a user's INBOX for unprocessed iTIP messages.
 * Returns an array of { uid, calendarData, method, from } objects.
 * @param {string} stalwartName - Stalwart principal name (for IMAP master-user auth)
 */
async function scanUserInbox(stalwartName) {
  const client = createImapClient(stalwartName);
  const results = [];

  try {
    await client.connect();

    const mailbox = await client.mailboxOpen('INBOX');
    log('debug', 'Opened INBOX', { user: stalwartName, exists: mailbox.exists });
    if (!mailbox.exists || mailbox.exists === 0) {
      return results;
    }

    // Search for unprocessed messages.
    // Stalwart may not support keyword flag searches ($CalendarProcessed),
    // returning undefined instead of throwing. Fall back to all messages
    // and filter by flags client-side in the fetch loop.
    let uids;
    try {
      uids = await client.search({
        not: { flag: '$CalendarProcessed' },
      });
    } catch {
      // Keyword flag search not supported
    }

    if (!uids || !Array.isArray(uids)) {
      log('debug', 'Keyword search not supported, falling back to all messages', { user: stalwartName });
      uids = await client.search({ all: true });
    }

    log('debug', 'Search results', { user: stalwartName, unprocessedCount: uids?.length || 0 });

    if (!uids || uids.length === 0) {
      return results;
    }

    // Limit to last 100 messages to avoid processing huge backlogs
    const recentUids = uids.slice(-100);

    // Phase 1: Collect messages with calendar parts (metadata only).
    // Do NOT issue download commands inside the fetch iterator — IMAP
    // doesn't allow interleaved commands during a multi-message FETCH.
    const candidates = [];
    for await (const msg of client.fetch(recentUids, {
      uid: true,
      flags: true,
      bodyStructure: true,
      envelope: true,
    })) {
      if (msg.flags && msg.flags.has('$CalendarProcessed')) {
        continue;
      }

      const calendarParts = findCalendarParts(msg.bodyStructure);
      if (calendarParts.length === 0) {
        continue;
      }

      log('debug', 'Found calendar part(s)', {
        user: stalwartName,
        uid: msg.uid,
        subject: msg.envelope?.subject,
        parts: calendarParts,
      });

      candidates.push({
        uid: msg.uid,
        calendarParts,
        from: msg.envelope?.from?.[0]?.address || 'unknown',
      });
    }

    // Phase 2: Download calendar data from each candidate message.
    for (const candidate of candidates) {
      for (const part of candidate.calendarParts) {
        try {
          const partData = await client.download(candidate.uid, part.path, { uid: true });
          const chunks = [];
          for await (const chunk of partData.content) {
            chunks.push(chunk);
          }
          const calendarData = Buffer.concat(chunks).toString('utf-8');

          const method = parseICalMethod(calendarData);
          if (method) {
            results.push({
              uid: candidate.uid,
              calendarData,
              method,
              from: candidate.from,
            });
          }
        } catch (err) {
          log('warn', 'Failed to download calendar part', {
            user: stalwartName,
            uid: candidate.uid,
            part: part.path,
            error: err.message,
          });
        }
      }
    }
  } catch (err) {
    // Auth failures manifest as "Unexpected close" when Stalwart closes the
    // connection after rejecting auth. These are common for misconfigured
    // accounts. Log at debug level since processUser() already logs the warning.
    const isAuthIssue = err.authenticationFailed || err.message === 'Unexpected close';
    const level = isAuthIssue ? 'debug' : 'error';
    log(level, 'IMAP scan failed', { user: stalwartName, error: err.message });
    throw err;
  } finally {
    try {
      await client.logout();
    } catch {
      // Ignore logout errors
    }
  }

  return results;
}

/**
 * Mark a message as processed by adding the $CalendarProcessed flag.
 */
async function markAsProcessed(stalwartName, uid) {
  const client = createImapClient(stalwartName);

  try {
    await client.connect();
    await client.mailboxOpen('INBOX');
    await client.messageFlagsAdd(uid, ['$CalendarProcessed'], { uid: true });
    log('debug', 'Marked message as processed', { user: stalwartName, uid });
  } finally {
    try {
      await client.logout();
    } catch {
      // Ignore logout errors
    }
  }
}

// ---------------------------------------------------------------------------
// Retry tracking and dead-letter helpers
// ---------------------------------------------------------------------------

/**
 * Build a retry tracker key from stalwart name and message UID.
 */
function retryTrackerKey(stalwartName, uid) {
  return `${stalwartName}:${uid}`;
}

/**
 * Check if a message should be skipped because it's in a backoff window.
 * Returns true if the message has a retry entry and the backoff hasn't expired.
 */
function shouldSkipMessage(stalwartName, uid) {
  const key = retryTrackerKey(stalwartName, uid);
  const entry = retryTracker.get(key);
  if (!entry) return false;
  return Date.now() < entry.nextRetryAfter;
}

/**
 * Record a processing failure for a message. Increments retry count and
 * computes exponential backoff delay.
 * Returns true if max retries exceeded (message should be dead-lettered).
 */
function recordFailure(stalwartName, uid, errorMessage) {
  const key = retryTrackerKey(stalwartName, uid);
  const entry = retryTracker.get(key) || { retries: 0, nextRetryAfter: 0, lastError: '' };
  entry.retries++;
  entry.lastError = errorMessage;
  const delay = Math.min(RETRY_BASE_DELAY_MS * Math.pow(2, entry.retries - 1), RETRY_MAX_DELAY_MS);
  entry.nextRetryAfter = Date.now() + delay;
  retryTracker.set(key, entry);

  log('warn', 'Message processing failed, backing off', {
    user: stalwartName,
    uid,
    retries: entry.retries,
    nextRetryMs: delay,
    error: errorMessage,
  });

  return entry.retries >= MAX_RETRIES;
}

/**
 * Move a message to the dead-letter folder (INBOX/iTIP-Failed).
 * Flags the message with $CalendarProcessed BEFORE moving, because
 * IMAP MOVE changes the message UID.
 */
async function moveToDeadLetter(stalwartName, uid) {
  const client = createImapClient(stalwartName);

  try {
    await client.connect();
    await client.mailboxOpen('INBOX');

    // Create dead-letter folder if it doesn't exist
    try {
      await client.mailboxCreate(DEAD_LETTER_FOLDER);
      log('info', 'Created dead-letter folder', { user: stalwartName, folder: DEAD_LETTER_FOLDER });
    } catch {
      // Folder already exists — this is fine
    }

    // Flag BEFORE move (move changes UID, so flag must come first)
    await client.messageFlagsAdd(uid, ['$CalendarProcessed'], { uid: true });
    await client.messageMove(uid, DEAD_LETTER_FOLDER, { uid: true });

    // Clean up retry tracker entry
    const key = retryTrackerKey(stalwartName, uid);
    retryTracker.delete(key);

    metrics.messagesDeadLettered++;
    log('warn', 'Dead-lettered message after max retries', {
      user: stalwartName,
      uid,
      folder: DEAD_LETTER_FOLDER,
    });
  } finally {
    try {
      await client.logout();
    } catch {
      // Ignore logout errors
    }
  }
}

/**
 * Prune stale entries from retryTracker and userBackoff maps.
 * Removes entries whose backoff window expired more than RETRY_STALE_MS ago.
 */
function pruneRetryTracker() {
  const now = Date.now();
  let prunedRetry = 0;
  let prunedBackoff = 0;

  for (const [key, entry] of retryTracker) {
    if (now - entry.nextRetryAfter > RETRY_STALE_MS) {
      retryTracker.delete(key);
      prunedRetry++;
    }
  }

  for (const [key, entry] of userBackoff) {
    if (now - entry.nextRetryAfter > RETRY_STALE_MS) {
      userBackoff.delete(key);
      prunedBackoff++;
    }
  }

  if (prunedRetry > 0 || prunedBackoff > 0) {
    log('info', 'Pruned stale retry entries', {
      prunedRetry,
      prunedBackoff,
      remainingRetry: retryTracker.size,
      remainingBackoff: userBackoff.size,
    });
  }
}

/**
 * Recursively find text/calendar MIME parts in a bodyStructure.
 */
function findCalendarParts(structure, path) {
  const parts = [];
  if (!structure) return parts;

  path = path || '';

  if (structure.type === 'text/calendar' || structure.type === 'application/ics') {
    parts.push({ path: path || '1', type: structure.type });
    return parts;
  }

  if (structure.childNodes && structure.childNodes.length > 0) {
    for (let i = 0; i < structure.childNodes.length; i++) {
      const childPath = path ? `${path}.${i + 1}` : `${i + 1}`;
      parts.push(...findCalendarParts(structure.childNodes[i], childPath));
    }
  }

  return parts;
}

// ---------------------------------------------------------------------------
// iCal parsing
// ---------------------------------------------------------------------------

/**
 * Parse the METHOD from iCal data. Returns 'REQUEST', 'REPLY', 'CANCEL', or null.
 */
function parseICalMethod(icalData) {
  try {
    const jcal = ICAL.parse(icalData);
    const comp = new ICAL.Component(jcal);
    const method = comp.getFirstPropertyValue('method');
    return method ? method.toUpperCase() : null;
  } catch (err) {
    log('warn', 'Failed to parse iCal method', { error: err.message });
    return null;
  }
}

/**
 * Extract event details from iCal data.
 * Returns { uid, summary, dtstart, dtend, organizer, attendees, fullIcal } or null.
 */
function parseICalEvent(icalData) {
  try {
    const jcal = ICAL.parse(icalData);
    const comp = new ICAL.Component(jcal);
    const vevent = comp.getFirstSubcomponent('vevent');

    if (!vevent) {
      log('warn', 'No VEVENT found in iCal data');
      return null;
    }

    const event = new ICAL.Event(vevent);
    const attendees = vevent.getAllProperties('attendee').map((a) => ({
      value: a.getFirstValue(),
      partstat: a.getParameter('partstat') || 'NEEDS-ACTION',
      cn: a.getParameter('cn') || '',
    }));

    return {
      uid: event.uid,
      summary: event.summary || '(No subject)',
      dtstart: event.startDate?.toString() || null,
      dtend: event.endDate?.toString() || null,
      organizer: vevent.getFirstPropertyValue('organizer') || null,
      attendees,
      fullIcal: icalData,
    };
  } catch (err) {
    log('error', 'Failed to parse iCal event', { error: err.message });
    return null;
  }
}

/**
 * Strip the METHOD property from iCal data for CalDAV storage.
 * iTIP messages (REQUEST/REPLY/CANCEL) include METHOD, but CalDAV forbids it.
 */
function stripMethodForStorage(icalData) {
  try {
    const jcal = ICAL.parse(icalData);
    const comp = new ICAL.Component(jcal);
    comp.removeProperty('method');
    return comp.toString();
  } catch {
    // Fallback: regex removal
    return icalData.replace(/^METHOD:[^\r\n]*\r?\n/m, '');
  }
}

/**
 * Rewrite the attendee PARTSTAT for the given user to NEEDS-ACTION in the iCal data.
 * This creates a "tentative" entry -- the user hasn't accepted yet.
 */
function setAttendeeNeedsAction(icalData, userEmail) {
  try {
    const jcal = ICAL.parse(icalData);
    const comp = new ICAL.Component(jcal);
    const vevent = comp.getFirstSubcomponent('vevent');
    if (!vevent) return icalData;

    const attendees = vevent.getAllProperties('attendee');
    for (const attendee of attendees) {
      const value = attendee.getFirstValue() || '';
      if (value.toLowerCase().includes(userEmail.toLowerCase())) {
        attendee.setParameter('partstat', 'NEEDS-ACTION');
      }
    }

    return comp.toString();
  } catch {
    return icalData;
  }
}

/**
 * Update an attendee's PARTSTAT in existing iCal data based on a REPLY.
 */
function applyReplyToEvent(existingIcal, replyIcal) {
  try {
    const existingJcal = ICAL.parse(existingIcal);
    const existingComp = new ICAL.Component(existingJcal);
    const existingEvent = existingComp.getFirstSubcomponent('vevent');

    const replyJcal = ICAL.parse(replyIcal);
    const replyComp = new ICAL.Component(replyJcal);
    const replyEvent = replyComp.getFirstSubcomponent('vevent');

    if (!existingEvent || !replyEvent) return existingIcal;

    // Get the attendee from the reply
    const replyAttendees = replyEvent.getAllProperties('attendee');
    for (const replyAttendee of replyAttendees) {
      const replyEmail = (replyAttendee.getFirstValue() || '').toLowerCase();
      const replyPartstat = replyAttendee.getParameter('partstat') || 'NEEDS-ACTION';

      // Find and update matching attendee in existing event
      const existingAttendees = existingEvent.getAllProperties('attendee');
      for (const existing of existingAttendees) {
        const existingEmail = (existing.getFirstValue() || '').toLowerCase();
        if (existingEmail === replyEmail) {
          existing.setParameter('partstat', replyPartstat);
          log('debug', 'Updated attendee PARTSTAT', {
            email: replyEmail,
            partstat: replyPartstat,
          });
        }
      }
    }

    return existingComp.toString();
  } catch (err) {
    log('error', 'Failed to apply reply to event', { error: err.message });
    return existingIcal;
  }
}

// ---------------------------------------------------------------------------
// CalDAV operations
// ---------------------------------------------------------------------------

/**
 * Build the CalDAV URL for an event in a user's personal calendar.
 * Nextcloud user IDs are full email addresses (configured via --mapping-uid=email in OIDC).
 */
function caldavEventUrl(userEmail, eventUid) {
  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  return `${baseUrl}/calendars/${userEmail}/personal/${eventUid}.ics`;
}

/**
 * Per-user CalDAV app passwords.
 * Nextcloud CalDAV is user-scoped — admin cannot access other users' calendars.
 * We use Nextcloud app passwords (created via occ at deploy time) to authenticate
 * as each user for CalDAV operations.
 */
const caldavTokens = {};

function loadCaldavTokens() {
  try {
    const data = fs.readFileSync(config.caldav.tokenFile, 'utf-8');
    const tokens = JSON.parse(data);
    Object.assign(caldavTokens, tokens);
    log('info', 'Loaded CalDAV tokens', { userCount: Object.keys(tokens).length });
  } catch (err) {
    if (err.code === 'ENOENT') {
      log('warn', 'CalDAV token file not found, CalDAV operations will fail', {
        path: config.caldav.tokenFile,
      });
    } else {
      log('error', 'Failed to load CalDAV tokens', { error: err.message });
    }
  }
}

/**
 * Create CalDAV Basic auth header for a specific user.
 * Uses per-user app password if available, falls back to admin credentials.
 */
function caldavAuthHeader(userEmail) {
  const appPassword = caldavTokens[userEmail];
  if (appPassword) {
    return 'Basic ' + Buffer.from(`${userEmail}:${appPassword}`).toString('base64');
  }
  // Fallback to admin credentials (only works for admin's own calendars)
  if (config.caldav.adminUser && config.caldav.adminPassword) {
    return 'Basic ' + Buffer.from(
      `${config.caldav.adminUser}:${config.caldav.adminPassword}`
    ).toString('base64');
  }
  return null;
}

/**
 * GET an existing event from CalDAV. Returns the iCal string or null if not found.
 */
async function caldavGetEvent(userEmail, eventUid) {
  const url = caldavEventUrl(userEmail, eventUid);
  const auth = caldavAuthHeader(userEmail);
  if (!auth) {
    log('warn', 'No CalDAV credentials for user', { user: userEmail });
    return null;
  }

  try {
    const resp = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: auth,
      },
    });

    if (resp.status === 404) return null;
    if (!resp.ok) {
      log('warn', 'CalDAV GET failed', { url, status: resp.status });
      return null;
    }

    return await resp.text();
  } catch (err) {
    log('error', 'CalDAV GET error', { url, error: err.message });
    return null;
  }
}

/**
 * Find an event by its VEVENT UID using CalDAV REPORT.
 * Nextcloud may store events with a different filename than the VEVENT UID
 * (e.g., events created via the UI use generated UUIDs as filenames).
 * Returns { href, ical } or null if not found.
 */
async function caldavFindEventByUid(userEmail, eventUid) {
  const auth = caldavAuthHeader(userEmail);
  if (!auth) {
    log('warn', 'No CalDAV credentials for user', { user: userEmail });
    return null;
  }

  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  const calUrl = `${baseUrl}/calendars/${userEmail}/personal/`;

  // XML-escape the eventUid to prevent injection via crafted iCal UIDs
  const escapedUid = eventUid
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');

  const reportBody =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' +
    '<d:prop><d:getetag/><c:calendar-data/></d:prop>' +
    '<c:filter><c:comp-filter name="VCALENDAR">' +
    '<c:comp-filter name="VEVENT">' +
    '<c:prop-filter name="UID">' +
    `<c:text-match>${escapedUid}</c:text-match>` +
    '</c:prop-filter>' +
    '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>';

  try {
    const resp = await fetch(calUrl, {
      method: 'REPORT',
      headers: {
        Authorization: auth,
        'Content-Type': 'application/xml; charset=utf-8',
        Depth: '1',
      },
      body: reportBody,
    });

    if (!resp.ok && resp.status !== 207) {
      log('warn', 'CalDAV REPORT failed', { url: calUrl, status: resp.status });
      return null;
    }

    const xml = await resp.text();

    // Parse the multistatus response to extract href and calendar-data
    const hrefMatch = /<d:href>([^<]+)<\/d:href>/i.exec(xml);
    const calDataMatch = /<(?:cal:|c:|C:|caldav:)?calendar-data[^>]*>([\s\S]*?)<\/(?:cal:|c:|C:|caldav:)?calendar-data>/i.exec(xml);

    if (!hrefMatch || !calDataMatch) {
      return null;
    }

    const ical = calDataMatch[1]
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .trim();

    return { href: hrefMatch[1], ical };
  } catch (err) {
    log('error', 'CalDAV REPORT error', { url: calUrl, error: err.message });
    return null;
  }
}

/**
 * PUT a calendar event to a specific CalDAV URL (href from REPORT).
 */
async function caldavPutEventAt(href, userEmail, icalData) {
  const auth = caldavAuthHeader(userEmail);
  if (!auth) throw new Error(`No CalDAV credentials for user ${userEmail}`);

  // href is an absolute path like /remote.php/dav/calendars/user/personal/FILE.ics
  // Construct full URL from the CalDAV base URL's origin
  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  const origin = new URL(baseUrl).origin;
  const url = `${origin}${href}`;

  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: auth,
      'Content-Type': 'text/calendar; charset=utf-8',
      // Suppress Nextcloud's IMipPlugin from sending scheduling emails.
      // Without this, every programmatic PUT triggers an outbound iMIP,
      // creating a feedback loop with external mail providers (e.g. Gmail).
      'Schedule-Reply': 'F',
    },
    body: icalData,
  });

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`CalDAV PUT failed: ${resp.status} ${resp.statusText} - ${body}`);
  }

  log('debug', 'CalDAV PUT success', { url, status: resp.status });
}

/**
 * PUT (create or update) a calendar event via CalDAV.
 */
async function caldavPutEvent(userEmail, eventUid, icalData) {
  const url = caldavEventUrl(userEmail, eventUid);
  const auth = caldavAuthHeader(userEmail);
  if (!auth) throw new Error(`No CalDAV credentials for user ${userEmail}`);

  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: auth,
      'Content-Type': 'text/calendar; charset=utf-8',
      'Schedule-Reply': 'F',
    },
    body: icalData,
  });

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`CalDAV PUT failed: ${resp.status} ${resp.statusText} - ${body}`);
  }

  log('debug', 'CalDAV PUT success', { url, status: resp.status });
}

/**
 * DELETE a calendar event via CalDAV.
 */
async function caldavDeleteEvent(userEmail, eventUid) {
  const url = caldavEventUrl(userEmail, eventUid);
  const auth = caldavAuthHeader(userEmail);
  if (!auth) throw new Error(`No CalDAV credentials for user ${userEmail}`);

  const resp = await fetch(url, {
    method: 'DELETE',
    headers: {
      Authorization: auth,
    },
  });

  // 204 No Content = success, 404 = already gone (both are fine)
  if (resp.status === 404) {
    log('debug', 'CalDAV DELETE: event not found (already deleted)', { url });
    return;
  }

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`CalDAV DELETE failed: ${resp.status} ${resp.statusText} - ${body}`);
  }

  log('debug', 'CalDAV DELETE success', { url, status: resp.status });
}

/**
 * Ensure the user's personal calendar exists by making a PROPFIND request.
 * If it doesn't exist, try to create it via MKCALENDAR.
 */
async function ensureCalendarExists(userEmail) {
  const auth = caldavAuthHeader(userEmail);
  if (!auth) {
    log('warn', 'No CalDAV credentials for user, skipping calendar check', { user: userEmail });
    return false;
  }

  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  const calUrl = `${baseUrl}/calendars/${userEmail}/personal/`;

  try {
    const resp = await fetch(calUrl, {
      method: 'PROPFIND',
      headers: {
        Authorization: auth,
        Depth: '0',
        'Content-Type': 'application/xml',
      },
      body: '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
    });

    if (resp.status === 207 || resp.status === 200) {
      return true; // Calendar exists
    }

    if (resp.status === 404) {
      // Try to create the calendar
      log('info', 'Personal calendar not found, creating', { user: userEmail });
      const mkResp = await fetch(calUrl, {
        method: 'MKCALENDAR',
        headers: {
          Authorization: auth,
          'Content-Type': 'application/xml',
        },
        body: `<?xml version="1.0" encoding="utf-8"?>
<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:set>
    <d:prop>
      <d:displayname>Personal</d:displayname>
    </d:prop>
  </d:set>
</c:mkcalendar>`,
      });
      return mkResp.ok || mkResp.status === 201;
    }

    return false;
  } catch (err) {
    log('warn', 'Calendar existence check failed', { user: userEmail, error: err.message });
    return false;
  }
}

// ---------------------------------------------------------------------------
// iTIP processing logic
// ---------------------------------------------------------------------------

/**
 * Process a REQUEST (new invitation or update).
 * Creates a tentative calendar entry in the user's Nextcloud calendar.
 */
async function processRequest(userEmail, icalData) {
  const event = parseICalEvent(icalData);
  if (!event || !event.uid) {
    log('warn', 'Cannot process REQUEST: invalid event data', { user: userEmail });
    return false;
  }

  log('info', 'Processing REQUEST', {
    user: userEmail,
    eventUid: event.uid,
    summary: event.summary,
    organizer: event.organizer,
  });

  await ensureCalendarExists(userEmail);

  // Set attendee status to NEEDS-ACTION (tentative in the calendar)
  // Strip METHOD property — iTIP uses it but CalDAV storage forbids it
  const modifiedIcal = stripMethodForStorage(setAttendeeNeedsAction(icalData, userEmail));

  try {
    await caldavPutEvent(userEmail, event.uid, modifiedIcal);
  } catch (err) {
    // Nextcloud returns 400 "uid already exists" when the event exists at a different
    // filename (e.g., created by Nextcloud's internal scheduling). Treat as success.
    if (err.message && err.message.includes('already exists')) {
      log('info', 'Event already exists in calendar (likely via internal scheduling)', {
        user: userEmail,
        eventUid: event.uid,
        summary: event.summary,
      });
      return true;
    }
    throw err;
  }
  metrics.eventsCreated++;

  log('info', 'Event created/updated from REQUEST', {
    user: userEmail,
    eventUid: event.uid,
    summary: event.summary,
  });

  return true;
}

/**
 * Process a REPLY (attendee response to an existing invitation).
 * Updates the attendee PARTSTAT in the existing CalDAV event.
 *
 * Uses CalDAV REPORT to find the event by VEVENT UID, since Nextcloud
 * may store events with a different filename (e.g., events created via
 * the Nextcloud UI use generated UUIDs, not the VEVENT UID).
 */
async function processReply(userEmail, icalData) {
  const event = parseICalEvent(icalData);
  if (!event || !event.uid) {
    log('warn', 'Cannot process REPLY: invalid event data', { user: userEmail });
    return false;
  }

  log('info', 'Processing REPLY', {
    user: userEmail,
    eventUid: event.uid,
    attendees: event.attendees.map((a) => `${a.value}=${a.partstat}`),
  });

  // Find the existing event by UID using REPORT (handles filename mismatches)
  const found = await caldavFindEventByUid(userEmail, event.uid);
  if (!found) {
    log('warn', 'REPLY for unknown event, marking as processed to avoid retry loop', {
      user: userEmail,
      eventUid: event.uid,
    });
    return true;
  }

  log('debug', 'Found event via REPORT', {
    user: userEmail,
    eventUid: event.uid,
    href: found.href,
  });

  // Merge the reply into the existing event
  const updatedIcal = applyReplyToEvent(found.ical, icalData);
  await caldavPutEventAt(found.href, userEmail, updatedIcal);
  metrics.eventsUpdated++;

  log('info', 'Event updated from REPLY', {
    user: userEmail,
    eventUid: event.uid,
    href: found.href,
  });

  return true;
}

/**
 * Process a CANCEL (organizer cancels the event).
 * Deletes the event from the user's CalDAV calendar.
 */
async function processCancel(userEmail, icalData) {
  const event = parseICalEvent(icalData);
  if (!event || !event.uid) {
    log('warn', 'Cannot process CANCEL: invalid event data', { user: userEmail });
    return false;
  }

  log('info', 'Processing CANCEL', {
    user: userEmail,
    eventUid: event.uid,
    summary: event.summary,
  });

  await caldavDeleteEvent(userEmail, event.uid);
  metrics.eventsCancelled++;

  log('info', 'Event cancelled/deleted', {
    user: userEmail,
    eventUid: event.uid,
    summary: event.summary,
  });

  return true;
}

// ---------------------------------------------------------------------------
// Main polling loop
// ---------------------------------------------------------------------------

/**
 * Process a single user: scan inbox, process iTIP messages, mark as done.
 */
async function processUser(user) {
  const { name: stalwartName, email: userEmail } = user;

  // Check per-user backoff — skip entirely if user is in backoff window
  const ub = userBackoff.get(stalwartName);
  if (ub && Date.now() < ub.nextRetryAfter) {
    metrics.usersSkippedBackoff++;
    log('debug', 'Skipping user (in backoff)', {
      user: stalwartName,
      consecutiveFullFailures: ub.consecutiveFullFailures,
      nextRetryAfter: new Date(ub.nextRetryAfter).toISOString(),
    });
    return;
  }

  let messages;
  try {
    messages = await scanUserInbox(stalwartName);
  } catch (err) {
    // IMAP connection failures are non-fatal for individual users.
    // Auth-related issues (common for misconfigured accounts) are debug-level.
    const isAuthIssue = err.authenticationFailed || err.message === 'Unexpected close';
    log(isAuthIssue ? 'debug' : 'warn', 'Failed to scan inbox', { user, error: err.message });
    return;
  }

  if (messages.length === 0) return;

  log('info', `Found ${messages.length} iTIP message(s)`, { user: userEmail });

  let anySucceeded = false;

  for (const msg of messages) {
    // Skip messages that are in a backoff window from a previous failure
    if (shouldSkipMessage(stalwartName, msg.uid)) {
      metrics.messagesSkippedBackoff++;
      log('debug', 'Skipping message (in backoff)', {
        user: stalwartName,
        uid: msg.uid,
      });
      continue;
    }

    try {
      let processed = false;

      switch (msg.method) {
        case 'REQUEST':
          processed = await processRequest(userEmail, msg.calendarData);
          break;
        case 'REPLY':
          processed = await processReply(userEmail, msg.calendarData);
          break;
        case 'CANCEL':
          processed = await processCancel(userEmail, msg.calendarData);
          break;
        default:
          log('debug', `Ignoring iTIP method: ${msg.method}`, {
            user: userEmail,
            uid: msg.uid,
          });
          // Still mark as processed to avoid re-scanning
          processed = true;
      }

      if (processed) {
        await markAsProcessed(stalwartName, msg.uid);
        metrics.messagesProcessed++;
        anySucceeded = true;
      }
    } catch (err) {
      metrics.errors++;

      const maxExceeded = recordFailure(stalwartName, msg.uid, err.message);
      if (maxExceeded) {
        try {
          await moveToDeadLetter(stalwartName, msg.uid);
        } catch (dlErr) {
          log('error', 'Failed to dead-letter message', {
            user: stalwartName,
            uid: msg.uid,
            error: dlErr.message,
          });
        }
      }
      // Continue processing other messages -- don't let one failure block the rest
    }
  }

  // Per-user backoff: if all messages are in the retry tracker (none succeeded),
  // increment consecutive failure count and back off the entire user
  if (messages.length > 0 && !anySucceeded) {
    const existing = userBackoff.get(stalwartName) || { consecutiveFullFailures: 0, nextRetryAfter: 0 };
    existing.consecutiveFullFailures++;
    const delay = Math.min(
      RETRY_BASE_DELAY_MS * Math.pow(2, existing.consecutiveFullFailures - 1),
      RETRY_MAX_DELAY_MS,
    );
    existing.nextRetryAfter = Date.now() + delay;
    userBackoff.set(stalwartName, existing);
    log('info', 'All messages failed for user, applying user-level backoff', {
      user: stalwartName,
      consecutiveFullFailures: existing.consecutiveFullFailures,
      nextRetryMs: delay,
    });
  } else if (anySucceeded) {
    userBackoff.delete(stalwartName);
  }
}

/**
 * Run one poll cycle: enumerate users, scan each user's inbox.
 */
async function pollCycle() {
  const startTime = Date.now();
  metrics.pollCycles++;

  // Periodically prune stale retry tracker entries
  if (metrics.pollCycles % RETRY_PRUNE_INTERVAL === 0) {
    pruneRetryTracker();
  }

  log('debug', 'Starting poll cycle', { cycle: metrics.pollCycles });

  try {
    const users = await listStalwartUsers();
    metrics.usersScanned = users.length;

    if (users.length === 0) {
      log('debug', 'No users found');
      return;
    }

    log('debug', `Scanning ${users.length} user(s)`);

    // Process users sequentially to avoid overwhelming IMAP/CalDAV
    for (const user of users) {
      try {
        await processUser(user);
      } catch (err) {
        metrics.errors++;
        log('error', 'Unexpected error processing user', {
          user,
          error: err.message,
        });
      }
    }

    metrics.healthy = true;
  } catch (err) {
    metrics.errors++;
    metrics.healthy = false;
    log('error', 'Poll cycle failed', { error: err.message, stack: err.stack });
  } finally {
    metrics.lastPollTime = new Date().toISOString();
    metrics.lastPollDurationMs = Date.now() - startTime;
    log('debug', 'Poll cycle complete', {
      durationMs: metrics.lastPollDurationMs,
      messagesProcessed: metrics.messagesProcessed,
    });
  }
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

let pollTimer = null;
let healthServer = null;

async function main() {
  log('info', 'Calendar automation service starting', {
    imapHost: config.imap.host,
    imapPort: config.imap.port,
    caldavBaseUrl: config.caldav.baseUrl,
    pollIntervalMs: config.pollIntervalMs,
  });

  // Load per-user CalDAV app passwords
  loadCaldavTokens();

  // Start health check server
  healthServer = startHealthServer();

  // Initial delay to let Stalwart finish starting up
  log('info', 'Waiting 10s for dependent services to be ready...');
  await new Promise((resolve) => setTimeout(resolve, 10000));

  // Run first poll immediately
  await pollCycle();

  // Schedule recurring polls
  pollTimer = setInterval(pollCycle, config.pollIntervalMs);

  log('info', 'Calendar automation service running', {
    pollIntervalSeconds: config.pollIntervalMs / 1000,
  });
}

// Graceful shutdown
function shutdown(signal) {
  log('info', `Received ${signal}, shutting down...`);

  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }

  const retrySize = retryTracker.size;
  const backoffSize = userBackoff.size;
  retryTracker.clear();
  userBackoff.clear();
  log('info', 'Cleared retry state', { retryTrackerEntries: retrySize, userBackoffEntries: backoffSize });

  if (healthServer) {
    healthServer.close(() => {
      log('info', 'Health server closed');
      process.exit(0);
    });
  } else {
    process.exit(0);
  }

  // Force exit after 10s if graceful shutdown stalls
  setTimeout(() => {
    log('warn', 'Forced exit after timeout');
    process.exit(1);
  }, 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Handle unhandled rejections (log and continue, don't crash)
process.on('unhandledRejection', (err) => {
  metrics.errors++;
  log('error', 'Unhandled rejection', { error: err?.message, stack: err?.stack });
});

main().catch((err) => {
  log('error', 'Fatal startup error', { error: err.message, stack: err.stack });
  process.exit(1);
});
