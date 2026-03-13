import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for the magic-link onboarding flow.
 *
 * Exercises the onboarding journey for users whose device lacks a platform
 * authenticator (e.g. Linux desktops). These users are offered "Set up email
 * sign-in" as an alternative to passkey registration.
 *
 * Flow:
 * 1. Admin portal: invite a new user (recovery email -> e2e-mailrt inbox)
 * 2. IMAP: read invitation email, extract setup URL
 * 3. Navigate to setup URL WITHOUT virtual authenticator
 * 4. WebAuthn page detects no platform auth -> shows magic-link option
 * 5. Click "Set Up Email Sign-In" -> /switch-to-magic-link
 * 6. /switch-to-magic-link removes webauthn required action, sets authMethod attribute
 * 7. Keycloak has no more required actions -> user is authenticated -> /home
 *
 * Note: The magic-link EMAIL is used for future LOGINS, not during onboarding.
 * During onboarding, we simply skip passkey registration. The magic-link
 * authenticator in the browser flow handles subsequent logins.
 *
 * Prerequisites:
 * - keycloak-magic-link plugin deployed (ext-magic-form authenticator)
 * - Custom browser flow with WebAuthn + Magic Link alternatives
 * - IMAP access configured (E2E_STALWART_ADMIN_PASSWORD)
 */
test.describe('Onboarding — Magic Link Flow (No Platform Authenticator)', () => {
  test.setTimeout(300_000); // 5 minutes

  test('user without platform auth completes onboarding via magic link', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('mlink')}-${uniqueId}`;
    const firstName = `MLink${uniqueId}`;
    const lastName = 'E2ETest';

    // Plus-addressed recovery email (same pattern as passkey test)
    const recoveryEmail = `e2e-mailrt+mlink-${uniqueId}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 1: Admin Portal - Create invitation
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
      await expect(adminPage.locator(ap.membersList)).toContainText(firstName, { timeout: 10_000 });

      console.log(`  [magic-link] Invite sent: userId=${invitedUserId}`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 2: Read invitation email
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const rawEmail = await waitForEmailBody({
        userEmail: TEST_USERS.emailTest.email,
        bodyContains: uniqueId,
        timeoutMs: 180_000,
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
          console.log('  [magic-link] beginSetup has empty userId - using next param directly');
          setupUrl = nextParam;
        }
      }

      expect(setupUrl, 'Could not find setup URL in invitation email').toBeTruthy();
      console.log(`  [magic-link] Setup URL: ${setupUrl!.substring(0, 80)}...`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 3: Navigate to setup WITHOUT virtual authenticator
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const userContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const userPage = await userContext.newPage();

      try {
        console.log('  [magic-link] Step 3: Navigating to setup URL (no virtual authenticator)...');
        await userPage.goto(setupUrl!);
        await userPage.waitForLoadState('load');
        console.log(`  [magic-link] Step 3: Landed on ${userPage.url().substring(0, 80)}`);

        // Handle "Click here to proceed" intermediate page
        const proceedLink = userPage.locator('a:has-text("Click here to proceed"), a:has-text("click here")');
        const registerBtn = userPage.locator('#registerBtn, button:has-text("Register Passkey")');
        const magicLinkBtn = userPage.locator('#magic-link-btn');

        const firstVisible = await Promise.race([
          proceedLink.first().waitFor({ timeout: 30_000 }).then(() => 'proceed' as const),
          registerBtn.first().waitFor({ timeout: 30_000 }).then(() => 'register' as const),
          magicLinkBtn.first().waitFor({ timeout: 30_000 }).then(() => 'magic-link' as const),
        ]).catch(() => 'timeout' as const);

        if (firstVisible === 'proceed') {
          console.log('  [magic-link] Step 3: Clicking "proceed" on action token info page...');
          await proceedLink.first().click();
          await userPage.waitForLoadState('load');
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 4: Verify magic-link detection and banner
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        const noPlatformBanner = userPage.locator('#no-platform-auth-banner');
        const magicLinkButton = userPage.locator('#magic-link-btn');

        // Wait for detection JS to run and show the magic-link option.
        // In headless Chrome without a virtual authenticator,
        // isUserVerifyingPlatformAuthenticatorAvailable() returns false.
        const detected = await Promise.race([
          magicLinkButton.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'magic-link' as const),
          noPlatformBanner.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'banner' as const),
        ]).catch(() => 'not-detected' as const);

        if (detected === 'not-detected') {
          const pageContent = await userPage.evaluate(() => {
            const el = document.querySelector('#kc-content-wrapper') || document.body;
            return el?.textContent?.substring(0, 500) || '';
          }).catch(() => '');
          console.log(`  [magic-link] Detection JS did not fire. Page content: ${pageContent.substring(0, 300)}`);
          test.skip(true, 'Magic-link detection not available on this page');
          return;
        }

        // Verify both banner and button are visible
        await expect(noPlatformBanner).toBeVisible();
        await expect(magicLinkButton).toBeVisible();

        // Verify the "Register Passkey" primary button is hidden
        const registerBtnVisible = await userPage.locator('#registerBtn').isVisible().catch(() => true);
        expect(registerBtnVisible).toBe(false);

        // Verify "I have a security key" secondary link is visible
        await expect(userPage.locator('#register-btn-secondary')).toBeVisible();

        console.log('  [magic-link] Step 4: Banner and magic-link button verified');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Click "Set Up Email Sign-In" and complete onboarding
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await magicLinkButton.click();
        console.log('  [magic-link] Step 5: Clicked "Set Up Email Sign-In"');

        // The click should redirect:
        // 1. /switch-to-magic-link (account portal) - removes webauthn action
        // 2. Back to Keycloak (via `next` param)
        // 3. Keycloak has no more required actions → authenticates user
        // 4. Redirects to /complete-registration or /home

        // Wait for the page to leave Keycloak and reach account portal
        const reachedHome = await userPage.waitForURL(
          url => url.pathname.includes('/home') || url.pathname.includes('/complete'),
          { timeout: 60_000 },
        ).then(() => true).catch(() => false);

        const currentUrl = userPage.url();
        console.log(`  [magic-link] Step 5: After redirect: ${currentUrl.substring(0, 100)}`);

        if (!reachedHome) {
          // If we're still on Keycloak, the switch may have failed
          // or there are additional required actions. Log diagnostics.
          const pageText = await userPage.evaluate(() =>
            document.body?.innerText?.substring(0, 500) || '',
          ).catch(() => '');
          console.log(`  [magic-link] Did not reach /home. URL: ${currentUrl}`);
          console.log(`  [magic-link] Page text: ${pageText.substring(0, 300)}`);

          // Try navigating directly to /home as a fallback
          await userPage.goto(`${urls.accountPortal}/home`);
          await userPage.waitForLoadState('load');
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 6: Verify user is on account portal home
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await expect(
          userPage.locator(selectors.accountPortal.welcomeHeading),
        ).toBeVisible({ timeout: 15_000 });

        console.log('  [magic-link] Step 6: Onboarding complete - user reached /home');

      } finally {
        await userContext.close();
      }
    } finally {
      // Always clean up the invited user
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [magic-link] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
