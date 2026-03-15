import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import * as fs from 'fs';
import * as path from 'path';

// Load echo group config
const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

const echoGroupAddress = process.env.E2E_ECHO_GROUP_ADDRESS || config.echoGroupAddress;

/**
 * Helper: log into Roundcube via OIDC for the given page/user.
 * Triggers the OIDC flow directly, handles Keycloak login if no SSO session.
 */
async function roundcubeLogin(page: import('@playwright/test').Page, username: string, password: string) {
  await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);
  await page.waitForLoadState('networkidle');

  // Check hostname (not full URL) — the OIDC callback URL contains 'auth.' in
  // query params (iss=https://auth.../realms/...) which would false-positive.
  const onKeycloak = new URL(page.url()).hostname.startsWith('auth.');
  if (onKeycloak) {
    await keycloakLogin(page, username, password);
    await page.waitForLoadState('networkidle');
  }

  await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });
}

test.describe('Email — Round-Trip via Echo Group', () => {
  // This test verifies the full email path: outbound (Roundcube → Stalwart → Postfix → internet)
  // and inbound (internet → Postfix → Stalwart → inbox). It sends from one user (e2e-mailrt)
  // to an external echo group, which forwards to a different user (e2e-mailrcv) who is a
  // member of the group. Using two users avoids Stalwart's duplicate message detection
  // (same Message-ID in sender's Sent folder vs. the forwarded copy).
  test('send email to echo group and verify delivery to group member', async ({
    emailTestPage: senderPage,
    emailRecvPage: receiverPage,
  }) => {
    test.setTimeout(180_000); // Email round-trip through external echo group can take 2+ minutes

    // Fail fast with a clear message if echoGroupAddress is not configured
    expect(echoGroupAddress, 'Set E2E_ECHO_GROUP_ADDRESS env var or echoGroupAddress in e2e.config.json').toBeTruthy();
    expect(echoGroupAddress, 'echoGroupAddress must be a valid email, got: ' + echoGroupAddress).toContain('@');

    const sender = TEST_USERS.emailTest;
    const receiver = TEST_USERS.emailRecv;

    // ── Step 1: Sender logs into Roundcube and sends email to the echo group ──
    await roundcubeLogin(senderPage, sender.username, sender.password);

    await senderPage.getByRole('button', { name: 'Compose' }).click();
    const subjectInput = senderPage.getByRole('textbox', { name: 'Subject' });
    await subjectInput.waitFor({ timeout: 15_000 });

    const toInput = senderPage.locator('.recipient-input input').first();
    await toInput.waitFor({ state: 'visible', timeout: 10_000 });
    await toInput.click();
    await toInput.pressSequentially(echoGroupAddress);
    await toInput.press('Enter');

    const subject = `E2E Round-Trip Test ${Date.now()}`;
    await subjectInput.fill(subject);

    const bodyFrame = senderPage.frameLocator('iframe').first();
    await bodyFrame.locator('body').fill('E2E round-trip test message');

    await senderPage.getByRole('button', { name: 'Send' }).click();

    // Wait for send to complete (returns to inbox)
    await senderPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });

    // ── Step 1b: Verify sender identity has a display name (set by oauth_name plugin) ──
    // Navigate to Settings → Identities and check the default identity has a non-empty name.
    // This verifies the oauth_name plugin populated the identity from the OIDC "name" claim.
    await senderPage.goto(`${urls.webmail}/?_task=settings&_action=identities`);
    await senderPage.waitForLoadState('networkidle');

    // The identities list shows identity rows; click the first (default) one
    const identityRow = senderPage.locator('#identities-table tbody tr, .listing tbody tr').first();
    await identityRow.waitFor({ timeout: 10_000 });
    await identityRow.click();
    await senderPage.waitForTimeout(1000);

    // The identity edit form has a "Display name" input field
    const nameInput = senderPage.locator('input[name="_name"]');
    await nameInput.waitFor({ timeout: 10_000 });
    const identityName = await nameInput.inputValue();

    expect(
      identityName.trim().length,
      `Roundcube identity display name should be set from OIDC profile, but was empty. ` +
      `The oauth_name plugin should populate this from Keycloak's "name" claim on login.`,
    ).toBeGreaterThan(0);

    // Return to inbox before proceeding
    await senderPage.goto(`${urls.webmail}/?_task=mail`);
    await senderPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 15_000 });

    // ── Step 2: Receiver logs into Roundcube and polls for the forwarded email ──
    await roundcubeLogin(receiverPage, receiver.username, receiver.password);

    const maxWait = 120_000;
    const pollInterval = 5_000;
    let found = false;
    const start = Date.now();

    while (Date.now() - start < maxWait) {
      // Refresh inbox
      const refreshed = await receiverPage.getByRole('button', { name: /refresh|check/i }).first()
        .click({ timeout: 3000 }).then(() => true).catch(() => false);
      if (!refreshed) {
        await receiverPage.reload();
        await receiverPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 15_000 });
      }
      await receiverPage.waitForTimeout(2000);

      // Check if the email appears in the message list
      const hasSubject = await receiverPage.locator(`td:has-text("${subject}")`).first()
        .isVisible().catch(() => false);

      if (hasSubject) {
        found = true;
        break;
      }

      await receiverPage.waitForTimeout(pollInterval);
    }

    expect(found, `Expected email with subject "${subject}" to appear in receiver's inbox within ${maxWait / 1000}s`).toBe(true);
  });
});
