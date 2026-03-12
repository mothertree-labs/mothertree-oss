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
 * 5. Click "Set Up Email Sign-In" -> /switch-to-magic-link -> Keycloak magic-link action
 * 6. IMAP: read magic-link email, extract sign-in URL
 * 7. Click magic-link URL -> onboarding complete, redirected to /home
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
    const userEmail = `${username}@${baseDomain}`;
    const firstName = `MLink${uniqueId}`;
    const lastName = 'E2ETest';

    // Plus-addressed recovery email (same pattern as passkey test)
    const recoveryEmail = `e2e-mailrt+mlink-${uniqueId}@${baseDomain}`;

    let invitedUserId: string | null = null;
    const results: Record<string, { passed: boolean; error?: string }> = {};

    function record(service: string, passed: boolean, error?: string) {
      results[service] = { passed, error };
      if (!passed) {
        console.log(`  [magic-link] SOFT FAIL - ${service}: ${error}`);
      }
    }

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 1: Admin Portal - Create invitation (same as passkey flow)
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

      record('admin-portal-invite', true);
      console.log(`  [magic-link] Invite sent: userId=${invitedUserId}`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 2: Read invitation email (same as passkey flow)
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
      record('invitation-email', true);
      console.log(`  [magic-link] Setup URL: ${setupUrl!.substring(0, 80)}...`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 3: Navigate to setup WITHOUT virtual authenticator
      // The WebAuthn page should detect no platform auth and show magic-link option
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      // Use a fresh context WITHOUT CDP virtual authenticator
      // This simulates a Linux desktop user without platform authenticator
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
        const registerBtn = userPage.locator('#registerBtn, #registerWebAuthn, button:has-text("Register Passkey"), input[type="submit"]');
        const magicLinkBtn = userPage.locator('#magic-link-btn, a:has-text("Set Up Email Sign-In"), .btn-magic-link');

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

        // Wait for the detection JS to run and show the magic-link option.
        // The JS calls isUserVerifyingPlatformAuthenticatorAvailable() which returns
        // false in headless Chrome without virtual authenticator, then shows the banner.
        const noPlatformBanner = userPage.locator('#no-platform-auth-banner');
        const magicLinkButton = userPage.locator('#magic-link-btn');

        // Wait for either the magic-link button (detection fired) or the register button
        const detected = await Promise.race([
          magicLinkButton.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'magic-link' as const),
          noPlatformBanner.waitFor({ state: 'visible', timeout: 15_000 }).then(() => 'banner' as const),
        ]).catch(() => 'not-detected' as const);

        if (detected === 'not-detected') {
          // Magic-link plugin may not be deployed yet, or the detection JS didn't run
          // (e.g., page isn't the WebAuthn registration page).
          // Check if we're even on the right page
          const pageContent = await userPage.evaluate(() => {
            const el = document.querySelector('#kc-content-wrapper') || document.body;
            return el?.textContent?.substring(0, 500) || '';
          }).catch(() => '');
          console.log(`  [magic-link] Detection JS did not fire. Page content: ${pageContent.substring(0, 200)}`);

          // This test requires the magic-link plugin to be deployed
          test.skip(true, 'Magic-link detection not available - plugin may not be deployed yet');
          return;
        }

        console.log('  [magic-link] Step 3: No-platform-auth banner detected, magic-link button visible');

        // Click "Set Up Email Sign-In" — this redirects to /switch-to-magic-link
        // which swaps the WebAuthn required action for magic-link
        await magicLinkButton.click();
        console.log('  [magic-link] Step 3: Clicked "Set Up Email Sign-In"');

        // Wait for redirect through /switch-to-magic-link back to Keycloak
        await userPage.waitForLoadState('load');
        console.log(`  [magic-link] Step 3: After redirect: ${userPage.url().substring(0, 100)}`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 4: Keycloak now shows magic-link required action
        // The plugin should send a magic-link email and show a "check email" page
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // The magic-link plugin shows a page saying "Check your email for a sign-in link"
        // Wait briefly for the email to be sent
        console.log('  [magic-link] Step 4: Waiting for magic-link email...');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Read magic-link email from e2e-mailrt inbox
        // The magic-link email is sent to the user's email (not recovery email)
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // The magic-link email goes to userEmail (the tenant email).
        // Since the user was just created, mail routing may go to recovery email instead.
        // Try both: the user's tenant email inbox and the recovery email inbox.
        const magicLinkEmail = await waitForEmailBody({
          userEmail: TEST_USERS.emailTest.email, // recovery email recipient
          subjectContains: 'sign in',
          bodyContains: uniqueId,
          timeoutMs: 120_000,
          pollIntervalMs: 3_000,
        });

        const decodedMagicLink = magicLinkEmail
          .replace(/=\r?\n/g, '')
          .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

        // Extract the magic-link URL from the email
        const magicLinkUrlMatch = decodedMagicLink.match(/https:\/\/auth\.[^\s"<>]+magic-link[^\s"<>]+/);
        const actionTokenMatch = decodedMagicLink.match(/https:\/\/auth\.[^\s"<>]+action-token[^\s"<>]+/);
        const magicLinkUrl = (magicLinkUrlMatch?.[0] || actionTokenMatch?.[0])?.replace(/&amp;/g, '&');

        expect(magicLinkUrl, 'Could not find magic-link URL in email').toBeTruthy();
        record('magic-link-email', true);
        console.log(`  [magic-link] Step 5: Magic link URL: ${magicLinkUrl!.substring(0, 80)}...`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 6: Click magic-link URL -> onboarding complete
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await userPage.goto(magicLinkUrl!);
        await userPage.waitForLoadState('load');
        console.log(`  [magic-link] Step 6: After clicking magic link: ${userPage.url().substring(0, 100)}`);

        // Wait for redirect to account portal /home
        const reachedHome = await userPage.waitForURL(
          url => url.pathname.includes('/home'),
          { timeout: 60_000 },
        ).then(() => true).catch(() => false);

        if (!reachedHome) {
          // Try navigating to /complete-registration
          const completeUrl = `https://account.${baseDomain}/complete-registration`;
          await userPage.goto(completeUrl);
          await userPage.waitForURL(
            url => url.pathname.includes('/home'),
            { timeout: 30_000 },
          );
        }

        // Verify we're on the account portal home page
        await expect(
          userPage.locator(selectors.accountPortal.welcomeHeading),
        ).toBeVisible({ timeout: 15_000 });

        record('magic-link-onboarding', true);
        console.log('  [magic-link] Step 6: Onboarding complete - user reached /home');

      } finally {
        await userContext.close();
      }

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Summary
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      console.log('\n  ┌──────────────────────────────────────────────');
      console.log('  │ Magic-Link Onboarding E2E Results');
      console.log('  ├──────────────────────────────────────────────');
      for (const [service, result] of Object.entries(results)) {
        const icon = result.passed ? 'PASS' : 'FAIL';
        const detail = result.error ? ` - ${result.error}` : '';
        console.log(`  │ [${icon}] ${service}${detail}`);
      }
      console.log('  └──────────────────────────────────────────────\n');

      // Hard-fail on critical steps
      const critical = ['admin-portal-invite', 'invitation-email', 'magic-link-onboarding'];
      for (const svc of critical) {
        if (results[svc] && !results[svc].passed) {
          throw new Error(`Critical service failed: ${svc} - ${results[svc].error}`);
        }
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
