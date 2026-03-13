import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for magic-link LOGIN flow (returning user).
 *
 * Tests that a user who was onboarded via magic-link can log back in
 * using the "Sign in with email link" option on the login page.
 *
 * Flow:
 * 1. Setup: invite user, complete onboarding via magic-link (abbreviated)
 * 2. Sign out
 * 3. Navigate to login page
 * 4. Click "Sign in with email link"
 * 5. Enter tenant email
 * 6. Submit -> server sends magic-link email, shows "Check your email" page
 * 7. IMAP: read magic-link email, extract sign-in URL
 * 8. Click the magic-link URL -> Keycloak authenticates -> /home
 *
 * Prerequisites:
 * - keycloak-magic-link plugin deployed
 * - IMAP access configured (E2E_STALWART_ADMIN_PASSWORD)
 */
test.describe('Login — Magic Link Flow (Returning User)', () => {
  test.setTimeout(300_000); // 5 minutes

  test('returning magic-link user can log in via email link', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('mlogin')}-${uniqueId}`;
    const firstName = `MLogin${uniqueId}`;
    const lastName = 'E2ETest';
    const recoveryEmail = `e2e-mailrt+mlogin-${uniqueId}@${baseDomain}`;
    // Tenant email (what the user will use to log in after onboarding)
    const tenantEmail = `${username}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // SETUP: Create user and complete magic-link onboarding
      // (Abbreviated — full assertions are in the onboarding test)
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      console.log('  [mlogin] SETUP: Creating user via admin invite...');

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

      // Read invitation email
      console.log('  [mlogin] SETUP: Waiting for invitation email...');
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
        if (nextParam) setupUrl = nextParam;
      }

      expect(setupUrl, 'Could not find setup URL in invitation email').toBeTruthy();

      // Navigate to setup, go through magic-link onboarding
      const setupContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const setupPage = await setupContext.newPage();

      try {
        console.log('  [mlogin] SETUP: Navigating to setup URL...');
        await setupPage.goto(setupUrl!);
        await setupPage.waitForLoadState('load');

        // Handle "Click here to proceed" page
        const proceedLink = setupPage.locator('a:has-text("Click here to proceed"), a:has-text("click here")');
        if (await proceedLink.first().isVisible({ timeout: 10_000 }).catch(() => false)) {
          await proceedLink.first().click();
          await setupPage.waitForLoadState('load');
        }

        // Wait for magic-link button (device lacks platform authenticator in headless)
        const magicLinkButton = setupPage.locator('#magic-link-btn');
        await magicLinkButton.waitFor({ state: 'visible', timeout: 15_000 });

        // Click "Set Up Email Sign-In"
        await magicLinkButton.click();
        console.log('  [mlogin] SETUP: Clicked magic-link button');

        // Wait for "Check your email" page
        await setupPage.waitForLoadState('load');
        await expect(setupPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });

        // Read magic-link email
        console.log('  [mlogin] SETUP: Waiting for magic-link email...');
        const magicRawEmail = await waitForEmailBody({
          userEmail: TEST_USERS.emailTest.email,
          bodyContains: uniqueId,
          subjectContains: 'Complete your',
          timeoutMs: 120_000,
          pollIntervalMs: 3_000,
        });

        const decodedMagicEmail = magicRawEmail
          .replace(/=\r?\n/g, '')
          .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

        const setupMagicMatch = decodedMagicEmail.match(
          /https:\/\/auth\.[^\s"<>]+(?:action-token|magic-link)[^\s"<>]*/,
        );
        const setupAuthFallback = decodedMagicEmail.match(/https:\/\/auth\.[^\s"<>]+/);
        const setupMagicUrl = (setupMagicMatch?.[0] || setupAuthFallback?.[0])?.replace(/&amp;/g, '&');
        expect(setupMagicUrl, 'No magic-link URL in onboarding email').toBeTruthy();

        // Click magic link to complete onboarding
        await setupPage.goto(setupMagicUrl!);

        // Wait for /home (through /magic-link-landing -> /complete-registration -> /home)
        await setupPage.waitForURL(
          url => url.pathname.includes('/home'),
          { timeout: 60_000 },
        );

        await expect(setupPage.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 15_000 });
        console.log('  [mlogin] SETUP: Onboarding complete');

        // Sign out
        await setupPage.click(selectors.accountPortal.signOutLink);
        await setupPage.waitForLoadState('load');
        console.log('  [mlogin] SETUP: Signed out');

      } finally {
        await setupContext.close();
      }

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // TEST: Log in via magic-link as a returning user
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const loginContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const loginPage = await loginContext.newPage();

      try {
        // Step 1: Navigate to account portal login page
        console.log('  [mlogin] Step 1: Navigating to login page...');
        await loginPage.goto(urls.accountPortal);
        await loginPage.waitForLoadState('load');

        // Step 2: Click "Sign in with email link"
        const emailSignInLink = loginPage.locator('a:has-text("Sign in with email link")');
        await expect(emailSignInLink).toBeVisible({ timeout: 15_000 });
        await emailSignInLink.click();
        console.log('  [mlogin] Step 2: Clicked "Sign in with email link"');

        // Step 3: Enter tenant email and submit
        await loginPage.waitForLoadState('load');
        const emailInput = loginPage.locator('#magicLinkEmail');
        await expect(emailInput).toBeVisible({ timeout: 15_000 });
        await emailInput.fill(tenantEmail);

        await loginPage.locator('button[type="submit"]').click();
        console.log(`  [mlogin] Step 3: Submitted email: ${tenantEmail}`);

        // Step 4: Expect "Check your email" page
        await loginPage.waitForLoadState('load');
        await expect(loginPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });
        console.log('  [mlogin] Step 4: "Check your email" page displayed');

        // Step 5: Read magic-link login email from IMAP
        // The login magic-link is sent to the user's RECOVERY email (not tenant
        // email), so it arrives in the e2e-mailrt inbox. Use subjectContains
        // to distinguish the login email ("Sign in") from the onboarding one
        // ("Complete your").
        console.log('  [mlogin] Step 5: Polling IMAP for magic-link login email...');

        const loginMagicEmail = await waitForEmailBody({
          userEmail: TEST_USERS.emailTest.email,
          bodyContains: uniqueId,
          subjectContains: 'Sign in',
          timeoutMs: 120_000,
          pollIntervalMs: 3_000,
        });

        const decodedLoginEmail = loginMagicEmail
          .replace(/=\r?\n/g, '')
          .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

        const loginMagicMatch = decodedLoginEmail.match(
          /https:\/\/auth\.[^\s"<>]+(?:action-token|magic-link)[^\s"<>]*/,
        );
        const loginAuthFallback = decodedLoginEmail.match(/https:\/\/auth\.[^\s"<>]+/);
        const loginMagicUrl = (loginMagicMatch?.[0] || loginAuthFallback?.[0])?.replace(/&amp;/g, '&');

        expect(loginMagicUrl, 'Could not find magic-link URL in login email').toBeTruthy();
        console.log(`  [mlogin] Step 5: Magic-link URL: ${loginMagicUrl!.substring(0, 80)}...`);

        // Step 6: Click magic-link URL
        await loginPage.goto(loginMagicUrl!);
        console.log('  [mlogin] Step 6: Navigated to magic-link URL');

        // Wait for authentication + redirect to /home
        await loginPage.waitForURL(
          url => url.pathname.includes('/home') || url.pathname.includes('/complete'),
          { timeout: 60_000 },
        );

        const finalUrl = loginPage.url();
        if (finalUrl.includes('/complete')) {
          await loginPage.waitForURL(url => url.pathname.includes('/home'), { timeout: 30_000 });
        }

        // Step 7: Verify user is on account portal home
        await expect(
          loginPage.locator(selectors.accountPortal.welcomeHeading),
        ).toBeVisible({ timeout: 15_000 });

        console.log('  [mlogin] Step 7: Login complete - user reached /home');

      } finally {
        await loginContext.close();
      }
    } finally {
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [mlogin] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
