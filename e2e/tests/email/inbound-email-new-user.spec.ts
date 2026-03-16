/**
 * E2E test: Inbound email delivery to a newly invited user.
 *
 * Verifies fix for https://github.com/mothertree-labs/mothertree-oss/issues/189
 * where API-created Stalwart principals lacked the 'user' role, causing inbound
 * email to bounce with "security.unauthorized" / "This account is not authorized
 * to receive email".
 *
 * Flow:
 *   1. Admin portal invites a new user → creates Keycloak + Stalwart principal
 *   2. Sender (e2e-mailrt) sends email to the new user via Roundcube
 *   3. IMAP master-user checks the new user's inbox for delivery
 *   4. Cleanup: delete the user via admin portal API
 */

import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { selectors } from '../../helpers/selectors';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

async function roundcubeLogin(page: import('@playwright/test').Page, username: string, password: string) {
  await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);
  const kc = '#username:visible, #mt-password, #passkey-login-btn';
  const result = await Promise.race([
    page.locator('#messagelist, #mailboxlist, .mailbox-list').first().waitFor({ timeout: 45_000 }).then(() => 'inbox' as const),
    page.locator(kc).first().waitFor({ timeout: 45_000, state: 'attached' }).then(() => 'keycloak' as const),
  ]).catch(() => 'timeout' as const);

  if (result === 'keycloak') {
    await keycloakLogin(page, username, password);
  }
  await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });
}

test.describe('Email — Inbound Delivery to New User (#189)', () => {
  test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

  test('newly invited user can receive inbound email', async ({
    adminPage,
    emailTestPage: senderPage,
  }) => {
    test.setTimeout(180_000);

    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const uniqueUsername = `${e2ePrefix('mail')}-${uniqueId}`;
    const uniqueFirstName = `E2EMail${uniqueId}`;
    const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
    const newUserEmail = `${uniqueUsername}@${baseDomain}`;
    let invitedUserId: string | null = null;

    try {
      // ── Step 1: Invite user via admin portal ──────────────────────────
      await adminPage.fill(ap.firstNameInput, uniqueFirstName);
      await adminPage.fill(ap.lastNameInput, 'MailTest');
      await adminPage.fill(ap.emailUsernameInput, uniqueUsername);
      await adminPage.fill(ap.recoveryEmailInput, `${e2ePrefix('rcv')}-${uniqueId}@example.com`);

      const responsePromise = adminPage.waitForResponse(
        (r) => r.url().includes('/api/invite') && r.request().method() === 'POST',
      );
      await adminPage.click(ap.inviteSubmitBtn);
      const apiResponse = await responsePromise;
      const apiResult = await apiResponse.json();
      invitedUserId = apiResult.userId || null;

      await expect(adminPage.locator(ap.formMessage)).toBeVisible({ timeout: 30_000 });
      const messageText = await adminPage.locator(ap.formMessage).textContent();
      expect(messageText).toContain('successfully');

      // ── Step 2: Send email from e2e-mailrt to the new user ────────────
      const sender = TEST_USERS.emailTest;
      await roundcubeLogin(senderPage, sender.username, sender.password);

      // Wait for Roundcube JS app to finish initializing (rcmail.busy clears
      // after IMAP inbox load completes — large inboxes delay this)
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
      await toInput.pressSequentially(newUserEmail);
      await toInput.press('Enter');

      const subject = `E2E Inbound New User ${uniqueId}`;
      await subjectInput.fill(subject);

      const bodyFrame = senderPage.frameLocator('iframe').first();
      await bodyFrame.locator('body').fill('Testing inbound delivery to newly invited user');

      await senderPage.getByRole('button', { name: 'Send' }).click();
      await senderPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });

      // ── Step 3: Verify delivery via IMAP ──────────────────────────────
      const rawMime = await waitForEmailBody({
        userEmail: newUserEmail,
        subjectContains: subject,
        timeoutMs: 90_000,
        pollIntervalMs: 5_000,
      });

      expect(rawMime).toContain(subject);
      expect(rawMime).toContain('Testing inbound delivery to newly invited user');
    } finally {
      // ── Cleanup ───────────────────────────────────────────────────────
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId);
      }
    }
  });
});
