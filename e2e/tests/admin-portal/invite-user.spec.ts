import { test, expect } from '../../fixtures/authenticated';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';

test.describe('Admin Portal — Invite User', () => {
  // The adminPage fixture already authenticates and navigates to admin portal.

  test('successfully invites a new user', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const uniqueUsername = `e2e-invite-${uniqueId}`;
    const uniqueFirstName = `E2ETest${uniqueId}`;
    let invitedUserId: string | null = null;

    try {
      await page.fill(ap.firstNameInput, uniqueFirstName);
      await page.fill(ap.lastNameInput, 'Invited');
      await page.fill(ap.emailUsernameInput, uniqueUsername);
      // Use unique recovery email to avoid 409 conflicts with stale users
      await page.fill(ap.recoveryEmailInput, `e2e-test-${uniqueId}@example.com`);

      // Submit invite — the API creates Keycloak + Stalwart + Matrix accounts (slow)
      // Intercept the response to capture the userId for reliable cleanup
      const responsePromise = page.waitForResponse((r) => r.url().includes('/api/invite') && r.request().method() === 'POST');
      await page.click(ap.inviteSubmitBtn);
      const apiResponse = await responsePromise;
      const apiResult = await apiResponse.json();
      invitedUserId = apiResult.userId || null;

      // Wait for the formMessage to appear (success or error)
      await expect(page.locator(ap.formMessage)).toBeVisible({ timeout: 30_000 });
      const messageText = await page.locator(ap.formMessage).textContent();
      expect(messageText).toContain('successfully');

      // Verify user appears in the members list by their unique first name
      await expect(page.locator(ap.membersList)).toContainText(uniqueFirstName, { timeout: 10_000 });
    } finally {
      // Cleanup: always delete the invited user, even if the test failed
      if (invitedUserId) {
        await page.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId);
        // Verify user is removed from the list
        await expect(page.locator(ap.membersList)).not.toContainText(uniqueFirstName, { timeout: 10_000 }).catch(() => {
          console.log(`  [invite] Cleanup: user ${uniqueUsername} may still appear in list`);
        });
      }
    }
  });

  test('shows error for duplicate email', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;

    // Try to invite with an existing username
    await page.fill(ap.firstNameInput, 'Duplicate');
    await page.fill(ap.lastNameInput, 'Test');
    await page.fill(ap.emailUsernameInput, TEST_USERS.admin.username);
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

  test('cleanup via delete button removes the user from the list', async ({ adminPage: page }) => {
    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const uniqueUsername = `e2e-invite-${uniqueId}`;
    const uniqueFirstName = `E2ECleanup${uniqueId}`;
    let invitedUserId: string | null = null;

    try {
      // Create a user to test deletion
      await page.fill(ap.firstNameInput, uniqueFirstName);
      await page.fill(ap.lastNameInput, 'Cleanup');
      await page.fill(ap.emailUsernameInput, uniqueUsername);
      await page.fill(ap.recoveryEmailInput, `e2e-cleanup-${uniqueId}@example.com`);

      const responsePromise = page.waitForResponse((r) => r.url().includes('/api/invite') && r.request().method() === 'POST');
      await page.click(ap.inviteSubmitBtn);
      const apiResponse = await responsePromise;
      const apiResult = await apiResponse.json();
      invitedUserId = apiResult.userId || null;

      await expect(page.locator(ap.formMessage)).toBeVisible({ timeout: 30_000 });
      expect(await page.locator(ap.formMessage).textContent()).toContain('successfully');

      // Wait for user to appear in the list
      await expect(page.locator(ap.membersList)).toContainText(uniqueFirstName, { timeout: 10_000 });

      // Find the user's card and click the delete button
      page.on('dialog', (dialog) => dialog.accept());
      const cards = page.locator('#membersList > div');
      const count = await cards.count();
      let deleted = false;
      for (let i = 0; i < count; i++) {
        const cardText = await cards.nth(i).textContent().catch(() => '');
        if (cardText?.includes(uniqueFirstName)) {
          await cards.nth(i).locator('[data-action="delete-user"]').click();
          deleted = true;
          break;
        }
      }

      expect(deleted, 'Should find the user card and click delete').toBe(true);

      // Verify the user is removed from the list
      await expect(page.locator(ap.membersList)).not.toContainText(uniqueFirstName, { timeout: 10_000 });

      // Mark cleanup as done so finally block skips
      invitedUserId = null;
    } finally {
      // Fallback cleanup via API if UI delete didn't work
      if (invitedUserId) {
        await page.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch(() => {
          console.log(`  [cleanup-test] Fallback cleanup failed for ${uniqueUsername}`);
        });
      }
    }
  });

  test('user count stays below 100 (stale user accumulation check)', async ({ adminPage: page }) => {
    // Canary test: if stale E2E users accumulate due to broken cleanup,
    // this test fails early with a clear message instead of causing
    // confusing failures in other tests when the Keycloak max limit is hit.
    const response = await page.evaluate(() => fetch('/api/users').then((r) => r.json()));
    const userCount = Array.isArray(response) ? response.length : 0;

    expect(
      userCount,
      `User count is ${userCount} — stale E2E test users are likely accumulating. ` +
        'Check that invite-user cleanup is working and clean up stale users from Keycloak.',
    ).toBeLessThan(100);
  });
});
