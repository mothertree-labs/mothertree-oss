import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody } from '../../helpers/imap';

const baseDomain = urls.baseDomain;

/**
 * E2E test for the Keycloak-native magic-link path.
 *
 * When a user with NO credentials (no passkey, no password) enters their email
 * in the Keycloak login form, the Phase Two magic-link authenticator auto-selects
 * (it's the only available authenticator) and renders the styled `view-email.ftl`
 * page. This is different from the account-portal magic-link flow which uses
 * `/magic-link-login`.
 *
 * Flow:
 * 1. Admin invites user (creates Keycloak user with no credentials)
 * 2. Open fresh browser -> account portal -> redirected to Keycloak login
 * 3. Enter user's tenant email in Keycloak username field, submit
 * 4. Magic-link authenticator auto-selects -> styled "Check your email" page
 * 5. IMAP: read magic-link email, extract URL
 * 6. Navigate to magic-link URL -> authenticated -> account portal home
 */
test.describe('Keycloak Native Magic-Link (credential-less user)', () => {
  test.setTimeout(180_000); // 5 minutes

  test('credential-less user authenticates via Keycloak-native magic link', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('kcml')}-${uniqueId}`;
    const firstName = `KcMl${uniqueId}`;
    const lastName = 'E2ETest';
    const tenantEmail = `${username}@${baseDomain}`;

    // Plus-addressed recovery email -> lands in e2e-mailrt inbox
    const recoveryEmail = `e2e-mailrt+kcml-${uniqueId}@${baseDomain}`;

    let invitedUserId: string | null = null;

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 1: Admin Portal — Invite user (no credentials)
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

      console.log(`  [kc-magic-link] Invite sent: userId=${invitedUserId}, email=${tenantEmail}`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 2: Open fresh browser -> account portal -> Keycloak login
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      const userContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const userPage = await userContext.newPage();

      try {
        await userPage.goto(urls.accountPortal);
        await userPage.waitForLoadState('load');

        // Click "Sign in" if on the account portal landing page
        const signInBtn = userPage.locator(selectors.accountPortal.signInBtn);
        if (await signInBtn.isVisible({ timeout: 5_000 }).catch(() => false)) {
          await signInBtn.click();
          await userPage.waitForLoadState('load');
        }

        // Should be on Keycloak login page now
        console.log(`  [kc-magic-link] Step 2: On login page: ${userPage.url().substring(0, 80)}`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 3: Enter email in Keycloak username field
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // The Keycloak browser flow renders login-username.ftl first:
        // a #username input and a .continue-btn ("Continue with Passkey").
        // Submitting the email triggers Keycloak to evaluate available
        // authenticators — for a credential-less user, only magic-link
        // is available, so it auto-selects and shows view-email.ftl.
        const usernameInput = userPage.locator(selectors.keycloak.usernameInput);
        await expect(usernameInput).toBeVisible({ timeout: 15_000 });

        await usernameInput.fill(tenantEmail);

        // Submit via the continue button (login-username.ftl)
        const continueBtn = userPage.locator(selectors.keycloak.continueBtn);
        await expect(continueBtn).toBeVisible({ timeout: 5_000 });
        await continueBtn.click();

        console.log(`  [kc-magic-link] Step 3: Submitted email ${tenantEmail}`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 4: Assert styled "Check your email" page
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await userPage.waitForLoadState('load');

        // Verify "Check your email" text is visible (from our styled view-email.ftl)
        await expect(
          userPage.locator('text=Check your email'),
        ).toBeVisible({ timeout: 30_000 });

        // Verify user's email is displayed in the styled email box
        await expect(
          userPage.locator('#magic-link-email'),
        ).toBeVisible({ timeout: 5_000 });
        await expect(
          userPage.locator('#magic-link-email'),
        ).toContainText(tenantEmail);

        // Verify "Start over" link is present
        await expect(
          userPage.locator('a:has-text("Start over")'),
        ).toBeVisible({ timeout: 5_000 });

        console.log('  [kc-magic-link] Step 4: Styled "Check your email" page verified');

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Read magic-link email from IMAP
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        // After invitation, sendInvitationEmail swaps the user's primary
        // email to the recovery email. Keycloak sends the magic-link to
        // the user's primary email = recovery email, which is plus-addressed
        // to the e2e-mailrt inbox. Poll that mailbox.
        console.log('  [kc-magic-link] Step 5: Polling IMAP for magic-link email...');

        const magicLinkRawEmail = await waitForEmailBody({
          userEmail: TEST_USERS.emailTest.email,
          bodyContains: uniqueId,
          skipContaining: 'beginSetup',  // Skip the invitation email
          timeoutMs: 120_000,
          pollIntervalMs: 3_000,
        });

        const decodedEmail = magicLinkRawEmail
          .replace(/=\r?\n/g, '')
          .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

        // Extract the magic-link URL (Keycloak action-token URL)
        const magicLinkMatch = decodedEmail.match(
          /https:\/\/auth\.[^\s"<>]+(?:action-token|magic-link)[^\s"<>]*/,
        );
        const authLinkFallback = decodedEmail.match(
          /https:\/\/auth\.[^\s"<>]+/,
        );
        const magicLinkUrl = (magicLinkMatch?.[0] || authLinkFallback?.[0])?.replace(/&amp;/g, '&');

        expect(magicLinkUrl, 'Could not find magic-link URL in email').toBeTruthy();
        console.log(`  [kc-magic-link] Step 5: Magic-link URL: ${magicLinkUrl!.substring(0, 80)}...`);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 6: Navigate to magic-link URL -> authenticated
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        await userPage.goto(magicLinkUrl!);
        console.log('  [kc-magic-link] Step 6: Navigated to magic-link URL');

        // After magic-link authentication, Keycloak either:
        // a) Redirects to account portal (/home or /complete-registration)
        // b) Shows a required action page (e.g. webauthn-register) if the user
        //    was invited with requiredActions — this still proves auth succeeded
        // Wait for the URL to change away from the action-token URL
        await userPage.waitForURL(
          url => !url.href.includes('action-token'),
          { timeout: 60_000 },
        );

        const finalUrl = userPage.url();
        console.log(`  [kc-magic-link] Step 6: After magic-link: ${finalUrl.substring(0, 120)}`);

        // If we landed on account portal, verify home page
        if (finalUrl.includes('/home') || finalUrl.includes('/complete')) {
          if (finalUrl.includes('/complete')) {
            await userPage.waitForURL(url => url.pathname.includes('/home'), { timeout: 30_000 });
          }
          await expect(
            userPage.locator(selectors.accountPortal.welcomeHeading),
          ).toBeVisible({ timeout: 15_000 });
          console.log('  [kc-magic-link] Step 6: User authenticated and on /home');
        } else {
          // Landed on a Keycloak page (required action like webauthn-register).
          // The magic-link authentication succeeded — verify we're no longer
          // on the login page by checking the URL isn't the login action.
          expect(finalUrl).not.toContain('/authenticate');
          console.log('  [kc-magic-link] Step 6: Magic-link auth succeeded (landed on required action page)');
        }

      } finally {
        await userContext.close();
      }
    } finally {
      // Always clean up the invited user
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [kc-magic-link] Cleanup failed for ${username}: ${(err as Error).message}`);
        });
      }
    }
  });
});
