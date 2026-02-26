import { test, expect } from '../../fixtures/authenticated';
import { selectors } from '../../helpers/selectors';

test.describe('Admin Portal — Invite User', () => {
  // The adminPage fixture already authenticates and navigates to admin portal.

  test('successfully invites a new user', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const uniqueUsername = `e2e-invite-${uniqueId}`;
    const uniqueFirstName = `E2ETest${uniqueId}`;

    await page.fill(ap.firstNameInput, uniqueFirstName);
    await page.fill(ap.lastNameInput, 'Invited');
    await page.fill(ap.emailUsernameInput, uniqueUsername);
    // Use unique recovery email to avoid 409 conflicts with stale users
    await page.fill(ap.recoveryEmailInput, `e2e-test-${uniqueId}@example.com`);

    // Submit invite — the API creates Keycloak + Stalwart + Matrix accounts (slow)
    await page.click(ap.inviteSubmitBtn);

    // Wait for the formMessage to appear (success or error)
    await expect(page.locator(ap.formMessage)).toBeVisible({ timeout: 30_000 });
    const messageText = await page.locator(ap.formMessage).textContent();
    expect(messageText).toContain('successfully');

    // Verify user appears in the members list by their unique first name
    // (the invite flow changes the primary email to recovery email, so we can't match by username)
    await expect(page.locator(ap.membersList)).toContainText(uniqueFirstName, { timeout: 10_000 });

    // Cleanup: delete the invited user (best-effort)
    try {
      page.on('dialog', (dialog) => dialog.accept());
      const cards = page.locator('#membersList > div > div');
      const count = await cards.count();
      for (let i = 0; i < count; i++) {
        const cardText = await cards.nth(i).textContent().catch(() => '');
        if (cardText?.includes(uniqueFirstName)) {
          await cards.nth(i).locator('[data-action="delete-user"]').click();
          await expect(page.locator(ap.membersList)).not.toContainText(uniqueFirstName, { timeout: 10_000 });
          break;
        }
      }
    } catch {
      console.log(`  [invite] Cleanup failed for ${uniqueUsername} — manual cleanup needed`);
    }
  });

  test('shows error for duplicate email', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;

    // Try to invite with an existing username
    await page.fill(ap.firstNameInput, 'Duplicate');
    await page.fill(ap.lastNameInput, 'Test');
    await page.fill(ap.emailUsernameInput, 'e2e-admin');
    await page.fill(ap.recoveryEmailInput, 'dup@example.com');

    await page.click(ap.inviteSubmitBtn);

    // Should show an error
    await expect(page.locator(ap.formMessage)).toBeVisible({ timeout: 10_000 });
    await expect(page.locator(ap.formMessage)).toContainText(/already exists|conflict|error/i);
  });

  test('validates required fields', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;

    // Click submit without filling any fields
    await page.click(ap.inviteSubmitBtn);

    // HTML5 validation should prevent submission
    const isInvalid = await page.locator(ap.firstNameInput).evaluate(
      (el: HTMLInputElement) => !el.validity.valid,
    );
    expect(isInvalid).toBe(true);
  });
});
