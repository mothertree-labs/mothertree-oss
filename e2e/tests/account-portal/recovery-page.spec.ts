import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';

test.describe('Account Portal — Recovery Page', () => {
  test('renders the recovery form', async ({ page }) => {
    await page.goto(`${urls.accountPortal}/recover`);
    const ap = selectors.accountPortal;

    await expect(page.locator('text=Account Recovery')).toBeVisible();
    await expect(page.locator(ap.tenantEmailInput)).toBeVisible();
    await expect(page.locator(ap.recoveryEmailInput)).toBeVisible();
    await expect(page.locator(ap.sendRecoveryBtn)).toBeVisible();
  });

  test('validates required fields', async ({ page }) => {
    await page.goto(`${urls.accountPortal}/recover`);

    // Click submit without filling fields — HTML5 validation
    await page.click(selectors.accountPortal.sendRecoveryBtn);

    const tenantEmailInvalid = await page.locator(selectors.accountPortal.tenantEmailInput).evaluate(
      (el: HTMLInputElement) => !el.validity.valid,
    );
    expect(tenantEmailInvalid).toBe(true);
  });

  test('shows error for non-matching email pair', async ({ page }) => {
    await page.goto(`${urls.accountPortal}/recover`);
    const ap = selectors.accountPortal;

    await page.fill(ap.tenantEmailInput, `nonexistent@${urls.baseDomain}`);
    await page.fill(ap.recoveryEmailInput, 'wrong@example.com');
    await page.click(ap.sendRecoveryBtn);

    // The server responds with "No account found..." error on the page
    await expect(page.locator('text=/No account found|not found|no match|error/i')).toBeVisible({ timeout: 10_000 });
  });
});
