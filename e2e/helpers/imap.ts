/**
 * IMAP helper for E2E calendar tests.
 * Uses imapflow (same library as calendar-automation) with Stalwart
 * master-user authentication to plant iTIP emails in user inboxes.
 */

// @ts-expect-error — imapflow has no bundled types
import { ImapFlow } from 'imapflow';

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';

interface ImapConfig {
  host: string;
  port: number;
  adminPassword: string;
}

function getImapConfig(): ImapConfig | null {
  const adminPassword = process.env.E2E_STALWART_ADMIN_PASSWORD;
  if (!adminPassword) {
    return null;
  }

  return {
    host: process.env.E2E_STALWART_IMAP_HOST || `lb1.${baseDomain}`,
    port: parseInt(process.env.E2E_STALWART_IMAP_PORT || '9940', 10),
    adminPassword,
  };
}

/**
 * Check if IMAP/Stalwart credentials are configured.
 * Tests should skip gracefully if this returns false.
 */
export function isImapConfigured(): boolean {
  return !!process.env.E2E_STALWART_ADMIN_PASSWORD;
}

/**
 * Create an ImapFlow client for the given auth user string.
 */
function createClient(authUser: string, config: ImapConfig): typeof ImapFlow {
  return new ImapFlow({
    host: config.host,
    port: config.port,
    secure: true,
    auth: {
      user: authUser,
      pass: config.adminPassword,
    },
    tls: {
      rejectUnauthorized: false, // Dev/CI uses self-signed certs
    },
    connectionTimeout: 10_000, // 10s TCP connection timeout
    greetTimeout: 15_000,      // 15s IMAP greeting timeout
    logger: false,
  });
}

/**
 * Connect to IMAP as master on behalf of a user.
 *
 * Stalwart master-user auth uses the principal name (not email).
 * Some principals use "user@domain" as name, others use just "user".
 * We try email first, then fall back to short username.
 *
 * Retries the full candidate list up to 3 times with a delay to handle
 * transient connection issues (common when connecting via external ingress).
 */
async function connectAsMaster(
  userEmail: string,
  config: ImapConfig,
): Promise<typeof ImapFlow> {
  const username = userEmail.split('@')[0];
  const candidates = [userEmail, username];
  const maxAttempts = 3;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    for (const name of candidates) {
      const client = createClient(`${name}%master`, config);
      try {
        await client.connect();
        return client;
      } catch (err: unknown) {
        // Auth/connection failures manifest differently depending on the path:
        // - Direct/cluster-internal: "Authentication failed" or "Command failed"
        // - Via ingress/TLS proxy: "Unexpected close" or "Connection not available"
        const isRetryable =
          err instanceof Error &&
          (err.message.includes('Authentication failed') ||
            err.message.includes('Command failed') ||
            err.message.includes('Unexpected close') ||
            err.message.includes('Connection not available'));
        if (!isRetryable) throw err;
        await client.logout().catch(() => {});
      }
    }

    if (attempt < maxAttempts) {
      await new Promise((r) => setTimeout(r, 2_000));
    }
  }

  throw new Error(
    `IMAP master-user auth failed for ${userEmail} (tried: ${candidates.map((c) => c + '%master').join(', ')}, ${maxAttempts} attempts)`,
  );
}

/**
 * Append a MIME email with a text/calendar part to a user's INBOX.
 * This simulates receiving an external calendar invitation via email,
 * which calendar-automation will then pick up and process.
 *
 * Retries the full connect+append operation to handle transient IMAP
 * connection drops (common via external ingress in CI).
 */
export async function appendCalendarEmail(opts: {
  userEmail: string;
  mimeMessage: string;
}): Promise<void> {
  const config = getImapConfig();
  if (!config) {
    throw new Error(
      'IMAP not configured: E2E_STALWART_ADMIN_PASSWORD is not set',
    );
  }

  const maxAttempts = 3;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const client = await connectAsMaster(opts.userEmail, config);
    try {
      await client.append('INBOX', opts.mimeMessage, ['\\Recent']);
      return;
    } catch (err: unknown) {
      lastError = err;
      await client.logout().catch(() => {});
      if (attempt < maxAttempts) {
        await new Promise((r) => setTimeout(r, 2_000));
      }
    }
  }

  throw lastError;
}

/**
 * Count messages in the user's INBOX whose subject contains the given string.
 * Useful for asserting that no outbound scheduling emails were generated.
 */
export async function countInboxBySubject(opts: {
  userEmail: string;
  subjectContains: string;
}): Promise<number> {
  const config = getImapConfig();
  if (!config) {
    throw new Error(
      'IMAP not configured: E2E_STALWART_ADMIN_PASSWORD is not set',
    );
  }

  const client = await connectAsMaster(opts.userEmail, config);

  try {
    const mailbox = await client.mailboxOpen('INBOX');
    if (!mailbox.exists || mailbox.exists === 0) {
      return 0;
    }

    // Fetch all message envelopes and filter client-side (Stalwart SEARCH
    // by header is unreliable for substring matching)
    const uids = await client.search({ all: true });
    if (!uids || uids.length === 0) return 0;

    let count = 0;
    const needle = opts.subjectContains.toLowerCase();
    for await (const msg of client.fetch(uids, { uid: true, envelope: true })) {
      const subject = (msg.envelope?.subject || '').toLowerCase();
      if (subject.includes(needle)) {
        count++;
      }
    }

    return count;
  } finally {
    await client.logout().catch(() => {});
  }
}

/**
 * Poll for an email matching filter criteria and return its raw MIME source.
 * Useful for extracting action URLs from invitation/notification emails.
 *
 * Matches when ALL provided filters match (AND logic):
 * - `subjectContains`: substring match on the envelope subject
 * - `bodyContains`: substring match on the raw MIME source (covers both text and HTML parts)
 *
 * Polls every `pollIntervalMs` until the email appears or `timeoutMs` is reached.
 */
export async function waitForEmailBody(opts: {
  userEmail: string;
  subjectContains?: string;
  bodyContains?: string;
  timeoutMs?: number;
  pollIntervalMs?: number;
}): Promise<string> {
  const config = getImapConfig();
  if (!config) {
    throw new Error(
      'IMAP not configured: E2E_STALWART_ADMIN_PASSWORD is not set',
    );
  }

  const timeoutMs = opts.timeoutMs ?? 60_000;
  const pollIntervalMs = opts.pollIntervalMs ?? 3_000;
  const subjectNeedle = opts.subjectContains?.toLowerCase();
  const bodyNeedle = opts.bodyContains?.toLowerCase();
  const start = Date.now();

  // Phase 1: envelope-only polling — NEVER fetch source during polling.
  // ImapFlow's source fetch blocks the Node.js event loop during buffer
  // processing, preventing setTimeout callbacks from firing (no timeouts work).
  // Envelope-only fetches are fast and never block.
  let pollCount = 0;
  let matchedUid: number | null = null;

  while (Date.now() - start < timeoutMs) {
    pollCount++;
    let client: typeof ImapFlow | null = null;

    try {
      client = await connectAsMaster(opts.userEmail, config);
      const mailbox = await client.mailboxOpen('INBOX');

      const uids = await client.search({ all: true });
      if (uids && uids.length > 0) {
        const recentUids = uids.slice(-20);

        for await (const msg of client.fetch(recentUids, {
          uid: true,
          envelope: true,
        })) {
          const subject = (msg.envelope?.subject || '').toLowerCase();
          const subjectMatch = !subjectNeedle || subject.includes(subjectNeedle);

          // Check envelope To: addresses for bodyContains needle
          let envelopeToMatch = false;
          if (bodyNeedle && msg.envelope?.to) {
            for (const addr of msg.envelope.to) {
              if ((addr.address || '').toLowerCase().includes(bodyNeedle)) {
                envelopeToMatch = true;
                break;
              }
            }
          }

          if (subjectMatch && (envelopeToMatch || !bodyNeedle)) {
            matchedUid = msg.uid;
          }
        }
      }

      if (pollCount <= 3 || pollCount % 10 === 0) {
        console.log(`  [imap] Poll #${pollCount}: ${mailbox.exists ?? 0} msgs (${Math.round((Date.now() - start) / 1000)}s elapsed)`);
      }
    } catch (err) {
      console.log(`  [imap] Poll #${pollCount} error: ${(err as Error).message}`);
    } finally {
      if (client) {
        try { client.close(); } catch {}
      }
    }

    if (matchedUid) break;
    await new Promise((r) => setTimeout(r, pollIntervalMs));
  }

  // Phase 2: download source for matched UID on a fresh connection.
  // Use ImapFlow's download() (streaming) instead of fetch() — fetch() with
  // source:true silently yields zero results for UIDs found on other connections.
  if (matchedUid) {
    for (let attempt = 1; attempt <= 3; attempt++) {
      const srcClient = await connectAsMaster(opts.userEmail, config);
      try {
        await srcClient.mailboxOpen('INBOX');
        // download() streams a single message's content — more reliable than fetch()
        const dl = await srcClient.download(String(matchedUid), undefined, { uid: true });
        const chunks: Buffer[] = [];
        for await (const chunk of dl.content) {
          chunks.push(chunk as Buffer);
        }
        const raw = Buffer.concat(chunks).toString();
        if (raw) return raw;
        console.log(`  [imap] Source download attempt ${attempt}: empty result for uid=${matchedUid}`);
      } catch (err) {
        console.log(`  [imap] Source download attempt ${attempt} error: ${(err as Error).message}`);
      } finally {
        try { srcClient.close(); } catch {}
      }
    }
    throw new Error(`Found matching email (uid=${matchedUid}) but failed to download source after 3 attempts`);
  }

  const filters = [
    opts.subjectContains && `subject containing "${opts.subjectContains}"`,
    opts.bodyContains && `body containing "${opts.bodyContains}"`,
  ].filter(Boolean).join(' and ');

  // Diagnostic: log what IS in the inbox to aid debugging
  let diagnostic = '';
  try {
    const diagClient = await connectAsMaster(opts.userEmail, config);
    try {
      const mb = await diagClient.mailboxOpen('INBOX');
      diagnostic = ` (inbox has ${mb.exists ?? 0} message(s)`;
      if (mb.exists && mb.exists > 0) {
        const allUids = await diagClient.search({ all: true });
        const subjects: string[] = [];
        for await (const msg of diagClient.fetch(allUids.slice(-5), { uid: true, envelope: true })) {
          subjects.push(msg.envelope?.subject || '(no subject)');
        }
        diagnostic += `: ${subjects.map(s => `"${s}"`).join(', ')}`;
      }
      diagnostic += ')';
    } finally {
      await diagClient.logout().catch(() => {});
    }
  } catch {
    diagnostic = ' (could not read inbox for diagnostics)';
  }

  throw new Error(
    `Timed out waiting for email with ${filters} ` +
    `in ${opts.userEmail}'s inbox after ${timeoutMs}ms${diagnostic}`,
  );
}

/**
 * Check if a message with a matching subject exists in the user's Sent folder.
 * Returns true if found. Useful for verifying outgoing iTIP responses.
 */
export async function checkSentFolder(opts: {
  userEmail: string;
  subjectFilter: string;
}): Promise<boolean> {
  const config = getImapConfig();
  if (!config) {
    throw new Error(
      'IMAP not configured: E2E_STALWART_ADMIN_PASSWORD is not set',
    );
  }

  const client = await connectAsMaster(opts.userEmail, config);

  try {
    // Try common sent folder names
    const sentFolders = ['Sent', 'INBOX.Sent', 'Sent Items', 'Sent Messages'];
    for (const folder of sentFolders) {
      try {
        await client.mailboxOpen(folder);
        const messages = await client.search({
          header: { subject: opts.subjectFilter },
        });
        if (messages && messages.length > 0) {
          return true;
        }
      } catch {
        // Folder doesn't exist, try next
        continue;
      }
    }

    return false;
  } finally {
    await client.logout().catch(() => {});
  }
}
