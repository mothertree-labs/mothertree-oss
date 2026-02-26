import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';

test.describe('Admin Portal — Login', () => {
  // The adminPage fixture already authenticates and navigates to admin portal.
  test('admin user can access the dashboard', async ({ adminPage: page }) => {
    await expect(page.locator(selectors.adminPortal.adminHeading)).toBeVisible();
    await expect(page.locator(selectors.adminPortal.inviteForm)).toBeVisible();
    await expect(page.locator(selectors.adminPortal.membersList)).toBeVisible();
  });

  test('non-admin user is rejected', async ({ memberPage: page }) => {
    await page.goto(urls.adminPortal);

    // Click Sign In to trigger OIDC
    const signInLink = page.locator('a[href="/auth/login"]');
    if (await signInLink.isVisible({ timeout: 2000 }).catch(() => false)) {
      await signInLink.click();

      // Wait for redirect — Keycloak SSO should auto-complete for member
      await page.waitForLoadState('networkidle');
    }

    // Should see an error/forbidden page, not the dashboard
    const isAdminDashboard = await page.locator(selectors.adminPortal.adminHeading).isVisible({ timeout: 5000 }).catch(() => false);
    expect(isAdminDashboard).toBe(false);
  });

  test('admin can sign out', async ({ adminPage: page }) => {
    await page.click(selectors.adminPortal.signOutLink);
    await page.waitForLoadState('networkidle');

    // Should no longer see the admin dashboard
    await expect(page.locator(selectors.adminPortal.adminHeading)).not.toBeVisible();
  });
});
