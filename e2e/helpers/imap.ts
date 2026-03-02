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
