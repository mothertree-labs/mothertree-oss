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
 * Create an ImapFlow client authenticated as master on behalf of a user.
 * Uses Stalwart's master-user auth pattern: "user%master" with admin password.
 */
function createClient(userEmail: string, config: ImapConfig): typeof ImapFlow {
  return new ImapFlow({
    host: config.host,
    port: config.port,
    secure: true,
    auth: {
      user: `${userEmail}%master`,
      pass: config.adminPassword,
    },
    tls: {
      rejectUnauthorized: false, // Dev/CI uses self-signed certs
    },
    logger: false,
  });
}

/**
 * Append a MIME email with a text/calendar part to a user's INBOX.
 * This simulates receiving an external calendar invitation via email,
 * which calendar-automation will then pick up and process.
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

  const client = createClient(opts.userEmail, config);

  try {
    await client.connect();
    await client.append('INBOX', opts.mimeMessage, ['\\Recent']);
  } finally {
    await client.logout().catch(() => {});
  }
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

  const client = createClient(opts.userEmail, config);

  try {
    await client.connect();

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
