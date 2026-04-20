import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { isImapConfigured, waitForEmailBody, deleteEmailsBySubject } from '../../helpers/imap';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

const echoGroupAddress = process.env.E2E_ECHO_GROUP_ADDRESS || config.echoGroupAddress;

async function roundcubeLogin(page: import('@playwright/test').Page, username: string, password: string) {
  await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);
  await page.waitForLoadState('networkidle');

  const onKeycloak = new URL(page.url()).hostname.startsWith('auth.');
  if (onKeycloak) {
    await keycloakLogin(page, username, password);
    await page.waitForLoadState('networkidle');
  }

  await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });
}

/**
 * Parse every DKIM-Signature header block in a raw MIME message.
 *
 * DKIM-Signature headers are folded across multiple lines (RFC 5322 §2.2.3).
 * Unfold by joining continuation lines (lines starting with whitespace) back
 * onto the header line, then split the body into tag=value pairs separated
 * by ';'. Multiple signatures are allowed per RFC 6376 §3.6.
 */
function parseDkimSignatures(rawMime: string): Array<Record<string, string>> {
  const headerBlock = rawMime.split(/\r?\n\r?\n/, 1)[0];
  const unfolded = headerBlock.replace(/\r?\n[\t ]+/g, ' ');
  const lines = unfolded.split(/\r?\n/);
  const signatures: Array<Record<string, string>> = [];

  for (const line of lines) {
    const m = line.match(/^DKIM-Signature:\s*(.+)$/i);
    if (!m) continue;

    const tags: Record<string, string> = {};
    for (const part of m[1].split(';')) {
      const eq = part.indexOf('=');
      if (eq <= 0) continue;
      const key = part.slice(0, eq).trim();
      const value = part.slice(eq + 1).trim();
      if (key) tags[key] = value;
    }
    signatures.push(tags);
  }

  return signatures;
}

test.describe('Email — DKIM Signature on Outbound Mail', () => {
  test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

  // Verifies PR-1 of issue #349: per-tenant Stalwart signs outbound mail with
  // the tenant's DKIM key (d=<tenant email domain>, s=default). The test sends
  // via Roundcube to the external echo group and inspects the delivered copy
  // (received by a different group member) for Stalwart's signature.
  //
  // Presence + correct tags are sufficient — cryptographic verification is the
  // receiving MTA's job, not this test's.
  test('Stalwart signs outbound mail with the tenant DKIM key', async ({
    emailTestPage: senderPage,
  }) => {
    test.setTimeout(180_000);

    expect(echoGroupAddress, 'Set E2E_ECHO_GROUP_ADDRESS or echoGroupAddress in e2e.config.json').toBeTruthy();
    expect(echoGroupAddress, 'echoGroupAddress must be a valid email').toContain('@');

    const sender = TEST_USERS.emailTest;
    const receiver = TEST_USERS.emailRecv;
    const subject = `E2E DKIM Signature ${Date.now()}`;

    // Derive the tenant's email domain from the sender address — same source
    // of truth the deploy uses for EMAIL_DOMAIN and for the DKIM DNS record.
    const senderDomain = sender.email.split('@')[1];
    expect(senderDomain, 'sender email must include a domain').toBeTruthy();

    try {
      await roundcubeLogin(senderPage, sender.username, sender.password);

      await senderPage.waitForFunction(
        () => window.rcmail && window.rcmail.task === 'mail' && !window.rcmail.busy,
        { timeout: 30_000 },
      );
      await senderPage.getByRole('button', { name: 'Compose' }).click();
      const subjectInput = senderPage.getByRole('textbox', { name: 'Subject' });
      await subjectInput.waitFor({ timeout: 15_000 });

      const toInput = senderPage.locator('.recipient-input input').first();
      await toInput.waitFor({ state: 'visible', timeout: 10_000 });
      await toInput.click();
      await toInput.pressSequentially(echoGroupAddress);
      await toInput.press('Enter');

      await subjectInput.fill(subject);

      const bodyFrame = senderPage.frameLocator('iframe').first();
      await bodyFrame.locator('body').fill('E2E DKIM signature test');

      await senderPage.getByRole('button', { name: 'Send' }).click();
      await senderPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });

      const rawMime = await waitForEmailBody({
        userEmail: receiver.email,
        subjectContains: subject,
        timeoutMs: 150_000,
      });

      const signatures = parseDkimSignatures(rawMime);
      expect(
        signatures.length,
        `Expected at least one DKIM-Signature header in delivered mail, got 0. Raw headers:\n${rawMime.split(/\r?\n\r?\n/, 1)[0]}`,
      ).toBeGreaterThan(0);

      const tenantSig = signatures.find(
        (sig) => sig.d === senderDomain && sig.s === 'default',
      );
      expect(
        tenantSig,
        `Expected a DKIM-Signature with d=${senderDomain} and s=default. Found: ${JSON.stringify(signatures)}`,
      ).toBeTruthy();
    } finally {
      if (isImapConfigured()) {
        const deleted = await deleteEmailsBySubject({ userEmail: receiver.email, subjectContains: subject });
        if (deleted > 0) console.log(`  [cleanup] Deleted ${deleted} email(s) from ${receiver.email}`);
        const deletedSender = await deleteEmailsBySubject({ userEmail: sender.email, subjectContains: subject });
        if (deletedSender > 0) console.log(`  [cleanup] Deleted ${deletedSender} email(s) from ${sender.email}`);
      }
    }
  });
});
