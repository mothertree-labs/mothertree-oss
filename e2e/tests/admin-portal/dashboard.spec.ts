import { test, expect } from '../../fixtures/authenticated';
import { selectors } from '../../helpers/selectors';

test.describe('Admin Portal — Dashboard', () => {
  // The adminPage fixture already authenticates and navigates to admin portal.
  // No loginToPortal needed — saves HTTP requests against the rate limiter.

  test('shows members list with users', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;

    // Wait for the members list to load (replaces "Loading members...")
    await expect(page.locator(ap.membersList)).not.toContainText('Loading members...', { timeout: 10_000 });

    // Should contain at least the e2e-admin user
    await expect(page.locator(ap.membersList)).toContainText('e2e-admin');
  });

  test('shows guests section', async ({ adminPage: page }) => {
    await expect(page.locator(selectors.adminPortal.guestsList)).toBeVisible();
  });

  test('invite form has all required fields', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;

    await expect(page.locator(ap.firstNameInput)).toBeVisible();
    await expect(page.locator(ap.lastNameInput)).toBeVisible();
    await expect(page.locator(ap.emailUsernameInput)).toBeVisible();
    await expect(page.locator(ap.recoveryEmailInput)).toBeVisible();
    await expect(page.locator(ap.inviteSubmitBtn)).toBeVisible();
  });

  test('email domain suffix is displayed', async ({ adminPage: page }) => {
    const domainText = await page.locator(selectors.adminPortal.emailDomain).textContent();
    expect(domainText).toMatch(/@.+\..+/);
  });

  test('backfill quotas button is present', async ({ adminPage: page }) => {
    await expect(page.locator(selectors.adminPortal.backfillBtn)).toBeVisible();
  });

  test('guest register link points to account portal', async ({ adminPage: page }) => {
    const link = await page.locator(selectors.adminPortal.guestRegisterLink).getAttribute('href');
    expect(link).toContain('account.');
    expect(link).toContain('/register');
  });
});
