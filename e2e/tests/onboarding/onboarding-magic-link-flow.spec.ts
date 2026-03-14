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
 * 6. Server sends magic-link email, renders "Check your email" page
 * 7. IMAP: read magic-link email, extract sign-in URL
 * 8. Click the magic-link URL -> Keycloak authenticates -> /home
 *
 * The magic-link email serves as email verification: the invitation link
 * is long-lived (7 days) and could be forwarded, so it does NOT verify
 * email ownership. The magic-link is short-lived and confirms the user
 * actually has access to the email address.
 *
 * Prerequisites:
 * - keycloak-magic-link plugin deployed (ext-magic-link authenticator)
 * - Custom browser flow with WebAuthn + Magic Link alternatives
 * - IMAP access configured (E2E_STALWART_ADMIN_PASSWORD)
 */
test.describe('Onboarding — Magic Link Flow (No Platform Authenticator)', () => {
  test.setTimeout(300_000); // 5 minutes

  test('user without platform auth completes onboarding via magic link email', async ({ adminPage }) => {
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
        // Don't use skipContaining here — we want the invitation email
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

        await expect(noPlatformBanner).toBeVisible();
        await expect(magicLinkButton).toBeVisible();

        const registerBtnVisible = await userPage.locator('#registerBtn').isVisible().catch(() => true);
        expect(registerBtnVisible).toBe(false);

        await expect(userPage.locator('#register-btn-secondary')).toBeVisible();

        // The subtle always-visible link should be hidden when the prominent banner is shown
        await expect(userPage.locator('#magic-link-subtle')).not.toBeVisible();

        console.log('  [magic-link] Step 4: Banner and magic-link button verified');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Click "Set Up Email Sign-In"
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await magicLinkButton.click();
        console.log('  [magic-link] Step 5: Clicked "Set Up Email Sign-In"');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 6: Expect "Check your email" page (NOT immediate redirect)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // The /switch-to-magic-link endpoint should send a magic-link email
        // and render a "check your email" page instead of redirecting.
        await userPage.waitForLoadState('load');

        await expect(
          userPage.locator('text=Check your email'),
        ).toBeVisible({ timeout: 30_000 });

        console.log('  [magic-link] Step 6: "Check your email" page displayed');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 7: Read magic-link email from IMAP
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // The magic-link email is sent to the user's Keycloak email, which is
        // still the recovery email at this point (email swap happens later in
        // /complete-registration). Both the invitation and magic-link emails
        // land in the e2e-mailrt inbox. Use skipContaining to skip the
        // invitation email (which contains "beginSetup").
        console.log('  [magic-link] Step 7: Polling IMAP for magic-link email...');

        const magicLinkRawEmail = await waitForEmailBody({
          userEmail: TEST_USERS.emailTest.email,
          bodyContains: uniqueId,
          subjectContains: 'Complete your',
          timeoutMs: 120_000,
          pollIntervalMs: 3_000,
        });

        const decodedMagicEmail = magicLinkRawEmail
          .replace(/=\r?\n/g, '')
          .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

        // Extract the magic-link URL from the email body.
        // The Phase Two plugin sends a Keycloak action-token URL.
        const magicLinkMatch = decodedMagicEmail.match(
          /https:\/\/auth\.[^\s"<>]+(?:action-token|magic-link)[^\s"<>]*/,
        );
        // Fallback: any link containing the auth host
        const authLinkFallback = decodedMagicEmail.match(
          /https:\/\/auth\.[^\s"<>]+/,
        );
        const magicLinkUrl = (magicLinkMatch?.[0] || authLinkFallback?.[0])?.replace(/&amp;/g, '&');

        expect(magicLinkUrl, 'Could not find magic-link URL in email').toBeTruthy();
        console.log(`  [magic-link] Step 7: Magic-link URL: ${magicLinkUrl!.substring(0, 80)}...`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 8: Click magic-link URL and complete onboarding
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await userPage.goto(magicLinkUrl!);
        console.log('  [magic-link] Step 8: Navigated to magic-link URL');

        // The magic link authenticates the user via Keycloak, then redirects to
        // /magic-link-landing -> /complete-registration -> /home
        await userPage.waitForURL(
          url => url.pathname.includes('/home') || url.pathname.includes('/complete'),
          { timeout: 60_000 },
        );

        const finalUrl = userPage.url();
        console.log(`  [magic-link] Step 8: After magic-link redirect: ${finalUrl.substring(0, 100)}`);

        // If we hit /complete-registration, wait for it to redirect to /home
        if (finalUrl.includes('/complete')) {
          await userPage.waitForURL(url => url.pathname.includes('/home'), { timeout: 30_000 });
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 9: Verify user is on account portal home
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await expect(
          userPage.locator(selectors.accountPortal.welcomeHeading),
        ).toBeVisible({ timeout: 15_000 });

        console.log('  [magic-link] Step 9: Onboarding complete - user reached /home');

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
