import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for magic-link login starting from files.* (Nextcloud).
 *
 * Verifies that the "Sign in with email link" option is visible on Keycloak
 * login pages rendered for non-account-portal properties, and that the full
 * magic-link flow works end-to-end when initiated from files.*.
 *
 * Flow:
 * 1. Setup: invite user, complete onboarding via magic-link
 * 2. Navigate to files.* (not logged in) -> Keycloak login page
 * 3. Assert "Sign in with email link" is visible
 * 4. Click link -> account portal /magic-link-login
 * 5. Enter tenant email, submit -> "Check your email" page
 * 6. IMAP: read magic-link email, extract sign-in URL
 * 7. Click magic link -> Keycloak authenticates -> account portal /home
 * 8. Navigate to files.* -> SSO auto-logs in -> Nextcloud loads
 * 9. Cleanup: delete user
 */
test.describe('Magic Link from Files (Keycloak Login)', () => {
  test.setTimeout(180_000); // 5 minutes

  test('magic-link login option is available on Keycloak page when redirected from files', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const kc = selectors.keycloak;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('mlfiles')}-${uniqueId}`;
    const firstName = `MLFiles${uniqueId}`;
    const lastName = 'E2ETest';
    const recoveryEmail = `e2e-mailrt+mlfiles-${uniqueId}@${baseDomain}`;
    const tenantEmail = `${username}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // SETUP: Create user and complete magic-link onboarding
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      console.log('  [mlfiles] SETUP: Creating user via admin invite...');

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
      console.log('  [mlfiles] SETUP: Waiting for invitation email...');
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
        if (nextParam) setupUrl = nextParam;
      }

      expect(setupUrl, 'Could not find setup URL in invitation email').toBeTruthy();

      // Navigate to setup, go through magic-link onboarding
      const setupContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const setupPage = await setupContext.newPage();

      try {
        console.log('  [mlfiles] SETUP: Navigating to setup URL...');
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

        await magicLinkButton.click();
        console.log('  [mlfiles] SETUP: Clicked magic-link button');

        await setupPage.waitForLoadState('load');
        await expect(setupPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });

        // Read magic-link email
        console.log('  [mlfiles] SETUP: Waiting for magic-link email...');
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

        await setupPage.goto(setupMagicUrl!);

        await setupPage.waitForURL(
          url => url.pathname.includes('/home'),
          { timeout: 60_000 },
        );

        await expect(setupPage.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 15_000 });
        console.log('  [mlfiles] SETUP: Onboarding complete');

        await setupPage.click(selectors.accountPortal.signOutLink);
        await setupPage.waitForLoadState('load');
        console.log('  [mlfiles] SETUP: Signed out');

      } finally {
        await setupContext.close();
      }

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // TEST: Navigate to files.* -> Keycloak -> magic-link -> SSO
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const testContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const testPage = await testContext.newPage();

      try {
        // Step 1: Navigate to files.* (not logged in) -> redirects to Keycloak
        console.log('  [mlfiles] Step 1: Navigating to files (unauthenticated)...');
        await testPage.goto(urls.files);
        await testPage.waitForLoadState('load');

        // Should be on Keycloak login page (either login.ftl or login-username.ftl)
        await testPage.waitForURL(
          url => url.hostname.startsWith('auth.'),
          { timeout: 30_000 },
        );
        console.log(`  [mlfiles] Step 1: Redirected to Keycloak: ${testPage.url()}`);

        // Step 2: Assert "Sign in with email link" is visible
        const magicLinkOption = testPage.locator(kc.magicLinkLogin);
        await expect(magicLinkOption).toBeVisible({ timeout: 15_000 });
        console.log('  [mlfiles] Step 2: "Sign in with email link" is visible on Keycloak page');

        // Step 3: Click the link -> arrives at account portal /magic-link-login?next=<files-origin>
        await magicLinkOption.click();
        await testPage.waitForLoadState('load');

        await testPage.waitForURL(
          url => url.pathname.includes('/magic-link-login'),
          { timeout: 15_000 },
        );

        // Verify the next parameter is set to the files origin
        const magicLinkLoginUrl = new URL(testPage.url());
        const nextParam = magicLinkLoginUrl.searchParams.get('next');
        expect(nextParam, 'next parameter should be set to files origin').toBeTruthy();
        expect(nextParam).toContain('files.');
        console.log(`  [mlfiles] Step 3: Arrived at /magic-link-login with next=${nextParam}`);

        // Step 4: Enter tenant email and submit
        const emailInput = testPage.locator('#magicLinkEmail');
        await expect(emailInput).toBeVisible({ timeout: 15_000 });
        await emailInput.fill(tenantEmail);

        await testPage.locator('button[type="submit"]').click();
        console.log(`  [mlfiles] Step 4: Submitted email: ${tenantEmail}`);

        // Step 5: Expect "Check your email" page
        await testPage.waitForLoadState('load');
        await expect(testPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });
        console.log('  [mlfiles] Step 5: "Check your email" page displayed');

        // Step 6: Read magic-link login email from IMAP
        console.log('  [mlfiles] Step 6: Polling IMAP for magic-link login email...');

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
        console.log(`  [mlfiles] Step 6: Magic-link URL: ${loginMagicUrl!.substring(0, 80)}...`);

        // Step 7: Click magic-link URL -> authenticate -> redirect to files (via next param)
        await testPage.goto(loginMagicUrl!);

        // The magic-link flow should redirect to files.* (the original destination),
        // not /home, because the next parameter was preserved through the flow.
        await testPage.waitForURL(
          url => url.hostname.startsWith('files.') || url.pathname.includes('/home') || url.pathname.includes('/complete'),
          { timeout: 60_000 },
        );

        const finalUrl = testPage.url();
        if (finalUrl.includes('/complete') || finalUrl.includes('/home')) {
          // If we landed on account portal, wait for potential redirect to files
          await testPage.waitForURL(
            url => url.hostname.startsWith('files.'),
            { timeout: 30_000 },
          );
        }

        // Should now be on files.* — SSO session from magic-link auth allows direct access
        await testPage.waitForURL(
          url => url.hostname.startsWith('files.'),
          { timeout: 30_000 },
        );
        console.log(`  [mlfiles] Step 7: Magic-link login complete - redirected to files: ${testPage.url()}`);

      } finally {
        await testContext.close();
      }
    } finally {
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [mlfiles] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
