import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';

test.describe('Smoke — Jitsi (Video)', () => {
  // This test is excluded from CI project (needs camera/mic)
  // Only runs in the "manual" project with fake media devices

  test('Jitsi page loads successfully', async ({ page }) => {
    await page.goto(urls.jitsi);
    await page.waitForLoadState('networkidle');

    // Jitsi Meet welcome page should load
    // Look for typical Jitsi UI elements
    await expect(
      page.locator('#welcome_page, [class*="welcome"], input[name="room"], #enter_room_field').first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('can enter a room name', async ({ page }) => {
    await page.goto(urls.jitsi);
    await page.waitForLoadState('networkidle');

    const roomInput = page.locator('input[name="room"], #enter_room_field');
    if (await roomInput.first().isVisible()) {
      await roomInput.first().fill('e2e-test-room');
      // Verify the input was accepted
      const value = await roomInput.first().inputValue();
      expect(value).toContain('e2e-test-room');
    }
  });
});
