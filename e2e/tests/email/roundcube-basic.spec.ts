import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

const ROUNDCUBE_INBOX = '#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")';

/**
 * Navigate to Roundcube and wait for the inbox to load.
 *
 * Handles the OIDC redirect flow gracefully:
 * - If SSO session exists, Keycloak auto-redirects → inbox appears
 * - If credentials needed, completes Keycloak login first
 * - Avoids the `networkidle` + URL-check race condition where the page
 *   is caught mid-redirect on Keycloak during SSO auto-redirect
 */
async function navigateToRoundcube(
  page: import('@playwright/test').Page,
  username: string,
  password: string,
) {
  await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);

  // Race: wait for either Roundcube inbox (SSO completed) or Keycloak
  // login form (credentials needed). This avoids catching the page
  // mid-redirect during SSO auto-redirect.
  const kc = '#username:visible, #mt-password, #passkey-login-btn';
  const result = await Promise.race([
    page.locator(ROUNDCUBE_INBOX).first().waitFor({ timeout: 45_000 }).then(() => 'inbox' as const),
    page.locator(kc).first().waitFor({ timeout: 45_000, state: 'attached' }).then(() => 'keycloak' as const),
  ]).catch(() => 'timeout' as const);

  if (result === 'keycloak') {
    await keycloakLogin(page, username, password);
    await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 30_000 });
  } else if (result === 'timeout') {
    // Last resort: check where we ended up
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, username, password);
      await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 30_000 });
    }
    // Otherwise wait a bit more for inbox
    await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 15_000 });
  }
}

test.describe('Email — Roundcube Basic', () => {
  test('SSO login to Roundcube loads inbox', async ({ memberPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.member.username, TEST_USERS.member.password);

    await expect(
      page.locator(ROUNDCUBE_INBOX).first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('keyboard shortcuts plugin is active', async ({ memberPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.member.username, TEST_USERS.member.password);

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
    await navigateToRoundcube(page, TEST_USERS.member.username, TEST_USERS.member.password);

    // Click compose button
    await page.locator('button:has-text("Compose"), a.compose, [data-command="compose"]').first().click();

    // Should see the compose form with To and Subject fields
    await expect(
      page.locator('#_to, #compose-subject, textarea#composebody').first(),
    ).toBeVisible({ timeout: 15_000 });
  });
});
