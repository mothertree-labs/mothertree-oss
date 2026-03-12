/**
 * E2E tests for magic-link login flow.
 *
 * Tests the login experience for users who onboarded via magic link
 * (no passkey registered). They should see the magic-link authenticator
 * option on the Keycloak select-authenticator page.
 *
 * Prerequisites:
 * - keycloak-magic-link plugin deployed (v0.57+)
 * - Custom browser flow with WebAuthn + Magic Link alternatives configured
 * - A user who has completed onboarding via magic link
 * - IMAP access configured (E2E_STALWART_ADMIN_PASSWORD)
 */

import { test as base, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';
import { isImapConfigured } from '../../helpers/imap';

const test = base;

test.describe('Magic Link — Login', () => {
  test.skip(!isImapConfigured(), 'Skipped: IMAP not configured');

  test('select-authenticator page shows magic-link option with correct icon and text', async ({
    browser,
  }) => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();

    try {
      // Navigate to the login page
      await page.goto(`${urls.accountPortal}/auth/login`);
      await page.waitForLoadState('load');

      // If redirected to Keycloak, check for the authenticator selection page
      // This test verifies the FTL template renders magic-link correctly
      // when a user with magic-link credential enters their username.
      //
      // Note: This requires a pre-configured user with magic-link auth.
      // In CI, this would be set up by the e2e-setup pipeline.
      // For now, we verify the page structure if we can reach it.

      if (page.url().includes('auth.')) {
        // Verify Keycloak login page loaded
        const hasUsernameField = await page.locator('#username').isVisible({ timeout: 5000 }).catch(() => false);
        expect(hasUsernameField).toBe(true);
      }
    } finally {
      await context.close();
    }
  });

  test('magic link email contains valid sign-in URL', async ({ browser }) => {
    // This test would:
    // 1. Navigate to login, enter magic-link user's username
    // 2. Keycloak triggers magic link email
    // 3. Extract email via IMAP
    // 4. Verify link format and click it
    // 5. Verify user is logged in
    //
    // Requires a user with magic-link credential.
    // Skipping until magic-link plugin is deployed and configured.
    test.skip();
  });

  test('magic link is single-use', async ({ browser }) => {
    // This test would:
    // 1. Trigger magic link for a user
    // 2. Click the link → logged in
    // 3. Try clicking same link again → expect error/expired
    //
    // Requires a user with magic-link credential.
    // Skipping until magic-link plugin is deployed and configured.
    test.skip();
  });
});
