import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';

test.describe('Account Portal — Login', () => {
  test('redirects to home after login and shows welcome message', async ({ memberPage: page }) => {
    // The fixture already performed login — verify we're on the home page
    await expect(page).toHaveURL(new RegExp(`${urls.accountPortal}/(home)?$`));
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible();
  });

  test('shows user email on home page', async ({ memberPage: page }) => {
    const emailText = await page.locator('p.text-warm-gray').first().textContent();
    expect(emailText).toContain('e2e-member');
  });

  test('sign out redirects to login page', async ({ memberPage: page }) => {
    // Click sign out and wait for navigation to complete
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.click(selectors.accountPortal.signOutLink),
    ]);

    // After logout, should be on the unauthenticated page (may pass through Keycloak logout)
    // Wait for the page to settle
    await page.waitForLoadState('load');

    // The welcome heading (authenticated dashboard) should not be visible
    const hasWelcome = await page.locator(selectors.accountPortal.welcomeHeading).isVisible().catch(() => false);
    expect(hasWelcome).toBe(false);
  });
});
