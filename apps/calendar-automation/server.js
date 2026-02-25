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
 *   IMAP_PORT            - Stalwart IMAP port (default: 993)
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
    adminUser: requiredEnv('CALDAV_ADMIN_USER'),
    adminPassword: requiredEnv('CALDAV_ADMIN_PASSWORD'),
  },
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL_SECONDS || '60', 10) * 1000,
  healthPort: parseInt(process.env.HEALTH_PORT || '8080', 10),
  logLevel: process.env.LOG_LEVEL || 'info',
};

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
  if (body.data && body.data.items) {
    return body.data.items;
  }

  // Fallback: older API format returns { data: [...] }
  if (Array.isArray(body.data)) {
    return body.data;
  }

  log('warn', 'Unexpected Stalwart API response format', { body });
  return [];
}

// ---------------------------------------------------------------------------
// IMAP operations
// ---------------------------------------------------------------------------

/**
 * Connect to IMAP as admin on behalf of a user.
 * Stalwart supports master-user authentication: "user%admin" with admin password.
 */
function createImapClient(userEmail) {
  return new ImapFlow({
    host: config.imap.host,
    port: config.imap.port,
    secure: config.imap.secure,
    auth: {
      user: `${userEmail}%admin`,
      pass: config.stalwart.adminPassword,
    },
    tls: config.imap.tls,
    logger: false, // Suppress imapflow internal logging
  });
}

/**
 * Scan a user's INBOX for unprocessed iTIP messages.
 * Returns an array of { uid, calendarData, method, from } objects.
 */
async function scanUserInbox(userEmail) {
  const client = createImapClient(userEmail);
  const results = [];

  try {
    await client.connect();

    const mailbox = await client.mailboxOpen('INBOX');
    if (!mailbox.exists || mailbox.exists === 0) {
      return results;
    }

    // Search for messages that are NOT flagged as processed
    // and have content-type text/calendar (search by header)
    // Note: Not all IMAP servers support HEADER Content-Type search,
    // so we fetch recent messages and filter client-side
    let uids;
    try {
      // Try to search for messages without the $CalendarProcessed flag
      uids = await client.search({
        not: { flag: '$CalendarProcessed' },
      });
    } catch {
      // Fallback: search for all unseen/recent messages
      log('debug', 'Flag search not supported, falling back to all messages', { user: userEmail });
      uids = await client.search({ all: true });
    }

    if (!uids || uids.length === 0) {
      return results;
    }

    // Limit to last 100 messages to avoid processing huge backlogs
    const recentUids = uids.slice(-100);

    for await (const msg of client.fetch(recentUids, {
      uid: true,
      flags: true,
      bodyStructure: true,
      envelope: true,
    })) {
      // Skip already processed messages
      if (msg.flags && msg.flags.has('$CalendarProcessed')) {
        continue;
      }

      // Check if message has text/calendar parts
      const calendarParts = findCalendarParts(msg.bodyStructure);
      if (calendarParts.length === 0) {
        continue;
      }

      // Fetch the calendar part content
      for (const part of calendarParts) {
        try {
          const partData = await client.download(msg.uid, part.path, { uid: true });
          const chunks = [];
          for await (const chunk of partData.content) {
            chunks.push(chunk);
          }
          const calendarData = Buffer.concat(chunks).toString('utf-8');

          const method = parseICalMethod(calendarData);
          if (method) {
            results.push({
              uid: msg.uid,
              calendarData,
              method,
              from: msg.envelope?.from?.[0]?.address || 'unknown',
            });
          }
        } catch (err) {
          log('warn', 'Failed to download calendar part', {
            user: userEmail,
            uid: msg.uid,
            part: part.path,
            error: err.message,
          });
        }
      }
    }
  } catch (err) {
    log('error', 'IMAP scan failed', { user: userEmail, error: err.message });
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
async function markAsProcessed(userEmail, uid) {
  const client = createImapClient(userEmail);

  try {
    await client.connect();
    await client.mailboxOpen('INBOX');
    await client.messageFlagsAdd(uid, ['$CalendarProcessed'], { uid: true });
    log('debug', 'Marked message as processed', { user: userEmail, uid });
  } finally {
    try {
      await client.logout();
    } catch {
      // Ignore logout errors
    }
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
 */
function caldavEventUrl(userEmail, eventUid) {
  // Extract username from email (part before @)
  const username = userEmail.split('@')[0];
  // Nextcloud CalDAV path: /remote.php/dav/calendars/{username}/personal/{uid}.ics
  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  return `${baseUrl}/calendars/${username}/personal/${encodeURIComponent(eventUid)}.ics`;
}

/**
 * Create CalDAV Basic auth header using admin credentials.
 */
function caldavAuthHeader() {
  return 'Basic ' + Buffer.from(
    `${config.caldav.adminUser}:${config.caldav.adminPassword}`
  ).toString('base64');
}

/**
 * GET an existing event from CalDAV. Returns the iCal string or null if not found.
 */
async function caldavGetEvent(userEmail, eventUid) {
  const url = caldavEventUrl(userEmail, eventUid);

  try {
    const resp = await fetch(url, {
      method: 'GET',
      headers: {
        Authorization: caldavAuthHeader(),
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
 * PUT (create or update) a calendar event via CalDAV.
 */
async function caldavPutEvent(userEmail, eventUid, icalData) {
  const url = caldavEventUrl(userEmail, eventUid);

  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: caldavAuthHeader(),
      'Content-Type': 'text/calendar; charset=utf-8',
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

  const resp = await fetch(url, {
    method: 'DELETE',
    headers: {
      Authorization: caldavAuthHeader(),
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
  const username = userEmail.split('@')[0];
  const baseUrl = config.caldav.baseUrl.replace(/\/$/, '');
  const calUrl = `${baseUrl}/calendars/${username}/personal/`;

  try {
    const resp = await fetch(calUrl, {
      method: 'PROPFIND',
      headers: {
        Authorization: caldavAuthHeader(),
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
          Authorization: caldavAuthHeader(),
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
  const modifiedIcal = setAttendeeNeedsAction(icalData, userEmail);

  await caldavPutEvent(userEmail, event.uid, modifiedIcal);
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

  // Get the existing event
  const existingIcal = await caldavGetEvent(userEmail, event.uid);
  if (!existingIcal) {
    log('warn', 'REPLY for unknown event, skipping', {
      user: userEmail,
      eventUid: event.uid,
    });
    return false;
  }

  // Merge the reply into the existing event
  const updatedIcal = applyReplyToEvent(existingIcal, icalData);
  await caldavPutEvent(userEmail, event.uid, updatedIcal);
  metrics.eventsUpdated++;

  log('info', 'Event updated from REPLY', {
    user: userEmail,
    eventUid: event.uid,
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
async function processUser(userEmail) {
  let messages;
  try {
    messages = await scanUserInbox(userEmail);
  } catch (err) {
    // IMAP connection failures are non-fatal for individual users
    log('warn', 'Failed to scan inbox', { user: userEmail, error: err.message });
    return;
  }

  if (messages.length === 0) return;

  log('info', `Found ${messages.length} iTIP message(s)`, { user: userEmail });

  for (const msg of messages) {
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
        await markAsProcessed(userEmail, msg.uid);
        metrics.messagesProcessed++;
      }
    } catch (err) {
      metrics.errors++;
      log('error', 'Failed to process iTIP message', {
        user: userEmail,
        uid: msg.uid,
        method: msg.method,
        error: err.message,
        stack: err.stack,
      });
      // Continue processing other messages -- don't let one failure block the rest
    }
  }
}

/**
 * Run one poll cycle: enumerate users, scan each user's inbox.
 */
async function pollCycle() {
  const startTime = Date.now();
  metrics.pollCycles++;

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
    for (const userEmail of users) {
      try {
        await processUser(userEmail);
      } catch (err) {
        metrics.errors++;
        log('error', 'Unexpected error processing user', {
          user: userEmail,
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
