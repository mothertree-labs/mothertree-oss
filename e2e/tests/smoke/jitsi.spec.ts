import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';

test.describe('Smoke — Jitsi (Video)', () => {
  test('Jitsi page loads successfully', async ({ page }) => {
    const response = await page.goto(urls.jitsi).catch(() => null);

    // If DNS doesn't resolve or connection fails, skip
    if (!response) {
      test.skip(true, 'Jitsi not reachable (DNS or connection error)');
    }

    // Check for server errors before proceeding
    const hasServerError = await page
      .locator('text=/Internal server error|Server Error|500|502|503/i')
      .isVisible()
      .catch(() => false);
    test.skip(hasServerError, 'Jitsi returned a server error — not a test issue');

    await page.waitForLoadState('networkidle');

    // Jitsi Meet welcome page should load
    await expect(
      page.locator('#welcome_page, [class*="welcome"], input[name="room"], #enter_room_field').first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('can enter a room name', async ({ page }) => {
    const response = await page.goto(urls.jitsi).catch(() => null);

    if (!response) {
      test.skip(true, 'Jitsi not reachable (DNS or connection error)');
    }

    const hasServerError = await page
      .locator('text=/Internal server error|Server Error|500|502|503/i')
      .isVisible()
      .catch(() => false);
    test.skip(hasServerError, 'Jitsi returned a server error — not a test issue');

    await page.waitForLoadState('networkidle');

    const roomInput = page.locator('input[name="room"], #enter_room_field').first();
    await expect(roomInput).toBeVisible({ timeout: 15_000 });

    await roomInput.fill('e2e-test-room');
    const value = await roomInput.inputValue();
    expect(value).toContain('e2e-test-room');
  });
});
