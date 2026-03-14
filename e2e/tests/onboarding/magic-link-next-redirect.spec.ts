import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for magic-link login with destination URL preservation.
 *
 * Verifies that when a user is redirected from an app (e.g. docs.*) to Keycloak
 * login, and then uses the magic-link login flow, they are redirected back to the
 * original app after authentication — not to the account portal /home page.
 *
 * Flow:
 * 1. Setup: invite user, complete onboarding via magic-link
 * 2. Sign out
 * 3. Navigate to docs.* (unauthenticated) -> Keycloak login page
 * 4. Click "Sign in with email link" -> /magic-link-login?next=https://docs.*
 * 5. Enter tenant email, submit -> magic-link sent
 * 6. IMAP: read magic-link email, extract URL
 * 7. Click magic link -> Keycloak authenticates -> redirect to docs.* (not /home)
 * 8. Cleanup: delete user
 */
test.describe('Magic Link — Destination URL Preservation', () => {
  test.setTimeout(300_000); // 5 minutes

  test('magic-link login preserves destination URL through the auth flow', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const kc = selectors.keycloak;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('mlnext')}-${uniqueId}`;
    const firstName = `MLNext${uniqueId}`;
    const lastName = 'E2ETest';
    const recoveryEmail = `e2e-mailrt+mlnext-${uniqueId}@${baseDomain}`;
    const tenantEmail = `${username}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // SETUP: Create user and complete magic-link onboarding
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      console.log('  [mlnext] SETUP: Creating user via admin invite...');

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
      console.log('  [mlnext] SETUP: Waiting for invitation email...');
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

      // Navigate to setup, complete magic-link onboarding
      const setupContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const setupPage = await setupContext.newPage();

      try {
        console.log('  [mlnext] SETUP: Navigating to setup URL...');
        await setupPage.goto(setupUrl!);
        await setupPage.waitForLoadState('load');

        const proceedLink = setupPage.locator('a:has-text("Click here to proceed"), a:has-text("click here")');
        if (await proceedLink.first().isVisible({ timeout: 10_000 }).catch(() => false)) {
          await proceedLink.first().click();
          await setupPage.waitForLoadState('load');
        }

        const magicLinkButton = setupPage.locator('#magic-link-btn');
        await magicLinkButton.waitFor({ state: 'visible', timeout: 15_000 });
        await magicLinkButton.click();
        console.log('  [mlnext] SETUP: Clicked magic-link button');

        await setupPage.waitForLoadState('load');
        await expect(setupPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });

        console.log('  [mlnext] SETUP: Waiting for magic-link email...');
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
        console.log('  [mlnext] SETUP: Onboarding complete');

        await setupPage.click(selectors.accountPortal.signOutLink);
        await setupPage.waitForLoadState('load');
        console.log('  [mlnext] SETUP: Signed out');

      } finally {
        await setupContext.close();
      }

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // TEST: Navigate to docs.* -> Keycloak -> magic-link -> redirected to docs
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const testContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const testPage = await testContext.newPage();

      try {
        // Step 1: Navigate to docs.* (unauthenticated) -> redirects to Keycloak
        console.log('  [mlnext] Step 1: Navigating to docs (unauthenticated)...');
        await testPage.goto(urls.docs);
        await testPage.waitForLoadState('load');

        await testPage.waitForURL(
          url => url.hostname.startsWith('auth.'),
          { timeout: 30_000 },
        );
        console.log(`  [mlnext] Step 1: Redirected to Keycloak: ${testPage.url()}`);

        // Step 2: Click "Sign in with email link"
        const magicLinkOption = testPage.locator(kc.magicLinkLogin);
        await expect(magicLinkOption).toBeVisible({ timeout: 15_000 });
        await magicLinkOption.click();
        await testPage.waitForLoadState('load');

        // Step 3: Verify we're on /magic-link-login with the next parameter
        await testPage.waitForURL(
          url => url.pathname.includes('/magic-link-login'),
          { timeout: 15_000 },
        );

        const magicLinkLoginUrl = new URL(testPage.url());
        const nextParam = magicLinkLoginUrl.searchParams.get('next');
        expect(nextParam, 'next parameter should be set to docs origin').toBeTruthy();
        expect(nextParam).toContain('docs.');
        console.log(`  [mlnext] Step 3: Arrived at /magic-link-login with next=${nextParam}`);

        // Step 4: Enter tenant email and submit
        const emailInput = testPage.locator('#magicLinkEmail');
        await expect(emailInput).toBeVisible({ timeout: 15_000 });
        await emailInput.fill(tenantEmail);

        await testPage.locator('button[type="submit"]').click();
        console.log(`  [mlnext] Step 4: Submitted email: ${tenantEmail}`);

        // Step 5: Expect "Check your email" page
        await testPage.waitForLoadState('load');
        await expect(testPage.locator('text=Check your email')).toBeVisible({ timeout: 30_000 });
        console.log('  [mlnext] Step 5: "Check your email" page displayed');

        // Step 6: Read magic-link login email from IMAP
        console.log('  [mlnext] Step 6: Polling IMAP for magic-link login email...');

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
        console.log(`  [mlnext] Step 6: Magic-link URL: ${loginMagicUrl!.substring(0, 80)}...`);

        // Step 7: Click magic-link URL -> authenticate -> redirect to docs (not /home)
        await testPage.goto(loginMagicUrl!);

        // The magic-link flow should redirect to docs.* because the next parameter
        // was preserved in the session through: /magic-link-login POST -> session ->
        // /magic-link-landing -> /complete-registration -> /registration-callback -> redirect
        await testPage.waitForURL(
          url => url.hostname.startsWith('docs.') || url.pathname.includes('/home') || url.pathname.includes('/complete'),
          { timeout: 60_000 },
        );

        // Wait for final destination
        await testPage.waitForURL(
          url => url.hostname.startsWith('docs.'),
          { timeout: 30_000 },
        );

        console.log(`  [mlnext] Step 7: Magic-link login complete - redirected to docs: ${testPage.url()}`);

      } finally {
        await testContext.close();
      }
    } finally {
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [mlnext] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
