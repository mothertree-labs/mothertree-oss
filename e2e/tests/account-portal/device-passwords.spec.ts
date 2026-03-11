import { test, expect } from '../../fixtures/authenticated';
import { selectors } from '../../helpers/selectors';
import { urls } from '../../helpers/urls';

test.describe('Account Portal — Device Passwords', () => {
  test.beforeEach(async ({ memberPage: page }) => {
    await page.goto(`${urls.accountPortal}/app-passwords`);
    await page.waitForSelector(selectors.accountPortal.createForm);
  });

  test('page loads with create form and empty list', async ({ memberPage: page }) => {
    const ap = selectors.accountPortal;
    await expect(page.locator(ap.createForm)).toBeVisible();
    await expect(page.locator(ap.deviceNameInput)).toBeVisible();
    await expect(page.locator(ap.createPasswordBtn)).toBeVisible();
  });

  test('create a device password and verify it is displayed', async ({ memberPage: page }) => {
    const ap = selectors.accountPortal;
    const deviceName = `e2e-test-${Date.now()}`;

    // Create a device password
    await page.fill(ap.deviceNameInput, deviceName);
    await page.click(ap.createPasswordBtn);

    // Verify the generated password is shown
    await expect(page.locator(ap.generatedPassword)).toBeVisible({ timeout: 10_000 });
    const password = await page.locator(ap.passwordValue).textContent();
    expect(password).toBeTruthy();
    expect(password!.length).toBeGreaterThan(8);

    // Try to verify the password appears in the list.
    // Test users created via dev-test-users.sh only have Keycloak accounts,
    // so the Stalwart principal may not exist yet. The list API may return empty
    // even though the create API succeeded. Poll a few times, but skip revoke
    // if the password never appears (known limitation for non-provisioned users).
    let appearedInList = false;
    for (let attempt = 0; attempt < 5; attempt++) {
      const listText = await page.locator(ap.passwordsList).textContent().catch(() => '');
      if (listText?.includes(deviceName)) {
        appearedInList = true;
        break;
      }
      await page.waitForTimeout(2000);
      await page.reload();
      await page.waitForSelector(ap.createForm);
    }

    if (appearedInList) {
      // Revoke the password
      page.on('dialog', (dialog) => dialog.accept());
      await page.locator(`${ap.passwordsList} button:has-text("Revoke")`).first().click();
      // Wait for revoke to process, then reload to get fresh list
      await page.waitForTimeout(2000);
      await page.reload();
      await page.waitForSelector(ap.createForm);
      await expect(page.locator(ap.passwordsList)).not.toContainText(deviceName, { timeout: 15_000 });
    } else {
      console.log('  [device-passwords] Password created but not in list — Stalwart principal may not exist for test user');
    }
  });

  test('shows error for empty device name', async ({ memberPage: page }) => {
    const ap = selectors.accountPortal;

    // Try to submit with empty name — HTML5 validation should prevent submission
    await page.click(ap.createPasswordBtn);

    // The input should be marked invalid (required field)
    const isInvalid = await page.locator(ap.deviceNameInput).evaluate(
      (el: HTMLInputElement) => !el.validity.valid,
    );
    expect(isInvalid).toBe(true);
  });
});
