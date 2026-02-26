import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';

test.describe('Guest — Registration Page', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`${urls.accountPortal}/register`);
  });

  test('renders the registration form', async ({ page }) => {
    const g = selectors.guest;

    await expect(page.locator('text=Guest Registration')).toBeVisible();
    await expect(page.locator(g.registerForm)).toBeVisible();
    await expect(page.locator(g.firstNameInput)).toBeVisible();
    await expect(page.locator(g.lastNameInput)).toBeVisible();
    await expect(page.locator(g.submitBtn)).toBeVisible();
  });

  test('shows email input when no email param', async ({ page }) => {
    // Without ?email= param, should show the email input field
    await expect(page.locator(selectors.guest.emailInput)).toBeVisible();
  });

  test('validates required fields', async ({ page }) => {
    const g = selectors.guest;

    // Click submit without filling anything
    await page.click(g.submitBtn);

    // HTML5 validation should prevent submission
    const isInvalid = await page.locator(g.firstNameInput).evaluate(
      (el: HTMLInputElement) => !el.validity.valid,
    );
    expect(isInvalid).toBe(true);
  });

  test('rejects tenant domain emails', async ({ page }) => {
    const g = selectors.guest;

    await page.fill(g.firstNameInput, 'Test');
    await page.fill(g.lastNameInput, 'Guest');
    await page.fill(g.emailInput, `shouldfail@${urls.baseDomain}`);

    // Check policy consent if present
    const consent = page.locator(g.policyConsent);
    if (await consent.isVisible()) {
      await consent.check();
    }

    await page.click(g.submitBtn);

    // Should show domain rejection error
    await expect(page.locator(g.errorAlert)).toBeVisible();
    await expect(page.locator(g.errorMessage)).toContainText(/organization|admin/i);
  });

  test('login link points to Keycloak', async ({ page }) => {
    const link = await page.locator(selectors.guest.loginLink).getAttribute('href');
    expect(link).toContain('auth.');
  });
});
