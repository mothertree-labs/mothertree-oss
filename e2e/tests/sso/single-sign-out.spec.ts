import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { keycloakLogin } from '../../helpers/auth';
import { TEST_USERS } from '../../helpers/test-users';

test.describe('SSO — Single Sign-Out', () => {
  test('logout from account portal clears Keycloak session', async ({ memberPage: page }) => {
    // The memberPage fixture restores stored cookies, but a prior sign-out test
    // may have invalidated the Keycloak session server-side. Re-login if needed.
    const isLoggedIn = await page.locator(selectors.accountPortal.welcomeHeading).isVisible({ timeout: 5_000 }).catch(() => false);
    if (!isLoggedIn) {
      const signInBtn = page.locator(selectors.accountPortal.signInBtn);
      if (await signInBtn.isVisible({ timeout: 2_000 }).catch(() => false)) {
        await signInBtn.click();
      }
      if (page.url().includes('auth.')) {
        await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      }
      await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 10_000 });
    }

    // Sign out — this navigates through Keycloak's logout endpoint
    await page.locator(selectors.accountPortal.signOutLink).click();
    await page.waitForLoadState('load');

    // Try to access a protected page — should require re-authentication
    await page.goto(`${urls.accountPortal}/home`);
    await page.waitForLoadState('load');

    // Should be on the login page, not the dashboard
    const hasWelcome = await page.locator(selectors.accountPortal.welcomeHeading).isVisible({ timeout: 5000 }).catch(() => false);
    expect(hasWelcome).toBe(false);
  });

  test('logout from account portal clears admin portal session', async ({ adminPage: page }) => {
    // Navigate to account portal (SSO should carry over from admin login)
    await page.goto(`${urls.accountPortal}/home`);
    await page.waitForLoadState('load');

    // Wait for either the welcome heading (SSO worked) or sign-in button
    const welcomeVisible = await page.locator(selectors.accountPortal.welcomeHeading).isVisible({ timeout: 10_000 }).catch(() => false);
    if (!welcomeVisible) {
      // SSO didn't carry over — click sign in if available
      const signInBtn = page.locator(selectors.accountPortal.signInBtn);
      if (await signInBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
        await signInBtn.click();
        await page.waitForLoadState('load');
      }
    }

    // Sign out from account portal
    const signOutLink = page.locator(selectors.accountPortal.signOutLink);
    await expect(signOutLink).toBeVisible({ timeout: 10_000 });
    await signOutLink.click();
    await page.waitForLoadState('load');

    // Try to access admin portal — should require re-authentication
    await page.goto(urls.adminPortal);
    await page.waitForLoadState('load');

    // The admin portal should show the landing page (not the dashboard)
    // since the Keycloak session was cleared by the logout
    const adminHeadingVisible = await page.locator(selectors.adminPortal.adminHeading).isVisible({ timeout: 5000 }).catch(() => false);
    expect(adminHeadingVisible).toBe(false);
  });
});
