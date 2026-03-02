import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Email — Roundcube Basic', () => {
  test('SSO login to Roundcube loads inbox', async ({ memberPage: page }) => {
    await page.goto(urls.webmail);
    await page.waitForLoadState('networkidle');

    // If redirected to Keycloak, complete login
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle');
    }

    // Roundcube should show the mailbox interface
    await expect(
      page.locator('#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")').first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('keyboard shortcuts plugin is active', async ({ memberPage: page }) => {
    await page.goto(urls.webmail);
    await page.waitForLoadState('networkidle');

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle');
    }

    // Wait for Roundcube to fully load
    await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")', { timeout: 30_000 });

    // The keyboard_shortcuts plugin injects a link with id "keyboard_shortcuts_link"
    await expect(page.locator('#keyboard_shortcuts_link')).toBeAttached({ timeout: 10_000 });

    // Press '?' to open the shortcuts help dialog
    await page.keyboard.press('?');

    // The dialog div has id "keyboard_shortcuts_help" and becomes a jQuery UI dialog
    const dialog = page.locator('#keyboard_shortcuts_help');
    await expect(dialog).toBeVisible({ timeout: 5_000 });

    // Verify it contains expected shortcut labels
    const dialogText = await dialog.textContent();
    expect(dialogText).toContain('Compose');
    expect(dialogText).toContain('Reply');
  });

  test('can open compose form', async ({ memberPage: page }) => {
    await page.goto(urls.webmail);
    await page.waitForLoadState('networkidle');

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle');
    }

    // Wait for Roundcube to fully load
    await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")', { timeout: 30_000 });

    // Click compose button
    await page.locator('button:has-text("Compose"), a.compose, [data-command="compose"]').first().click();

    // Should see the compose form with To and Subject fields
    await expect(
      page.locator('#_to, #compose-subject, textarea#composebody').first(),
    ).toBeVisible({ timeout: 15_000 });
  });
});
