import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for the always-visible magic-link option on the WebAuthn registration page.
 *
 * Verifies that users whose device DOES support passkeys still see a subtle
 * "Sign up using a magic link instead" link as an alternative to passkey
 * registration. This is separate from the prominent banner/button shown when
 * the device lacks a platform authenticator (tested in onboarding-magic-link-flow).
 *
 * Flow:
 * 1. Admin portal: invite a new user
 * 2. IMAP: read invitation email, extract setup URL
 * 3. Navigate to setup URL WITH virtual authenticator (device supports passkeys)
 * 4. Assert: subtle magic-link link is visible, Register Passkey button is visible,
 *    no-platform-auth banner is NOT visible
 * 5. Click subtle magic-link link → /switch-to-magic-link → "Check your email" page
 */
test.describe('WebAuthn Register — Always-Visible Magic Link Option', () => {
  test.setTimeout(180_000);

  test('subtle magic-link link is visible when device supports passkeys', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const kc = selectors.keycloak;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('mlsub')}-${uniqueId}`;
    const firstName = `MLSub${uniqueId}`;
    const lastName = 'E2ETest';
    const recoveryEmail = `e2e-mailrt+mlsub-${uniqueId}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 1: Admin Portal — Create invitation
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      await adminPage.fill(ap.firstNameInput, firstName);
      await adminPage.fill(ap.lastNameInput, lastName);
      await adminPage.fill(ap.emailUsernameInput, username);
      await adminPage.fill(ap.recoveryEmailInput, recoveryEmail);

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

      console.log(`  [ml-subtle] Invite sent: userId=${invitedUserId}`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 2: Read invitation email
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const rawEmail = await waitForEmailBody({
        userEmail: TEST_USERS.emailTest.email,
        bodyContains: uniqueId,
        timeoutMs: 90_000,
        pollIntervalMs: 3_000,
      });

      const decodedEmail = rawEmail
        .replace(/=\r?\n/g, '')
        .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

      const urlMatch = decodedEmail.match(/https:\/\/account\.[^\s"<>]+beginSetup[^\s"<>]+/);
      const actionUrlFallback = decodedEmail.match(/https:\/\/auth\.[^\s"<>]+action-token[^\s"<>]+/);
      let setupUrl = (urlMatch?.[0] || actionUrlFallback?.[0])?.replace(/&amp;/g, '&');

      if (setupUrl?.includes('beginSetup?userId=&') || setupUrl?.includes('beginSetup?userId=&amp;')) {
        const nextParam = new URL(setupUrl).searchParams.get('next');
        if (nextParam) {
          console.log('  [ml-subtle] beginSetup has empty userId — using next param directly');
          setupUrl = nextParam;
        }
      }

      expect(setupUrl, 'Could not find setup URL in invitation email').toBeTruthy();
      console.log(`  [ml-subtle] Setup URL: ${setupUrl!.substring(0, 80)}...`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 3: Navigate to setup WITH virtual authenticator
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const userContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const userPage = await userContext.newPage();

      try {
        // Enable CDP virtual authenticator — device "supports" passkeys
        const cdpSession = await userPage.context().newCDPSession(userPage);
        await cdpSession.send('WebAuthn.enable');
        await cdpSession.send('WebAuthn.addVirtualAuthenticator', {
          options: {
            protocol: 'ctap2',
            transport: 'internal',
            hasResidentKey: true,
            hasUserVerification: true,
            isUserVerified: true,
          },
        });

        console.log('  [ml-subtle] Step 3: Navigating to setup URL (with virtual authenticator)...');
        await userPage.goto(setupUrl!);
        await userPage.waitForLoadState('load');
        console.log(`  [ml-subtle] Step 3: Landed on ${userPage.url().substring(0, 80)}`);

        // Handle "Click here to proceed" intermediate page
        const proceedLink = userPage.locator('a:has-text("Click here to proceed"), a:has-text("click here")');
        const registerBtn = userPage.locator('#registerBtn, button:has-text("Register Passkey")');

        const firstVisible = await Promise.race([
          proceedLink.first().waitFor({ timeout: 30_000 }).then(() => 'proceed' as const),
          registerBtn.first().waitFor({ timeout: 30_000 }).then(() => 'register' as const),
        ]).catch(() => 'timeout' as const);

        if (firstVisible === 'proceed') {
          console.log('  [ml-subtle] Step 3: Clicking "proceed" on action token info page...');
          await proceedLink.first().click();
          await userPage.waitForLoadState('load');
        } else if (firstVisible === 'timeout') {
          const visibleText = await userPage.evaluate(() => {
            const el = document.querySelector('#kc-content-wrapper') || document.body;
            return el?.innerText || '';
          }).catch(() => '');
          throw new Error(`Neither proceed link nor register button found. URL: ${userPage.url()}, text: ${visibleText.substring(0, 300)}`);
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 4: Verify page state — subtle link visible, banner NOT visible
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // Wait for the Register Passkey button (confirms we're on the right page)
        await expect(userPage.locator('#registerBtn')).toBeVisible({ timeout: 15_000 });

        // The subtle magic-link link should be visible
        const subtleLink = userPage.locator(kc.magicLinkSubtle);
        await expect(subtleLink).toBeVisible({ timeout: 10_000 });
        console.log('  [ml-subtle] Step 4: Subtle magic-link link is visible');

        // The link text should match
        await expect(userPage.locator(kc.magicLinkSubtleLink)).toContainText('magic link');

        // The href should point to /switch-to-magic-link
        const href = await userPage.locator(kc.magicLinkSubtleLink).getAttribute('href');
        expect(href).toContain('/switch-to-magic-link');
        expect(href).toContain('userId=');
        expect(href).toContain('token=');
        console.log(`  [ml-subtle] Step 4: Link href verified: ${href!.substring(0, 80)}...`);

        // The no-platform-auth banner should NOT be visible (device supports passkeys)
        await expect(userPage.locator('#no-platform-auth-banner')).not.toBeVisible();

        // The prominent magic-link button should NOT be visible
        await expect(userPage.locator('#magic-link-btn')).not.toBeVisible();

        // The "I have a security key" secondary option should NOT be visible
        await expect(userPage.locator('#register-btn-secondary')).not.toBeVisible();

        console.log('  [ml-subtle] Step 4: All visibility assertions passed');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Click subtle link → verify "Check your email" page
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await userPage.locator(kc.magicLinkSubtleLink).click();
        console.log('  [ml-subtle] Step 5: Clicked subtle magic-link link');

        await userPage.waitForLoadState('load');
        await expect(
          userPage.locator('text=Check your email'),
        ).toBeVisible({ timeout: 30_000 });

        console.log('  [ml-subtle] Step 5: "Check your email" page displayed — test passed');

      } finally {
        await userContext.close();
      }
    } finally {
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [ml-subtle] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
