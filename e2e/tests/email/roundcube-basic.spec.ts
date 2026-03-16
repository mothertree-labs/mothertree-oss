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
 * - If page ends up mid-redirect on Keycloak, retries the OAuth URL
 */
async function navigateToRoundcube(
  page: import('@playwright/test').Page,
  username: string,
  password: string,
) {
  // Attempt the OIDC flow (with one retry for transient redirect issues)
  for (let attempt = 0; attempt < 2; attempt++) {
    await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);

    // Race: wait for either Roundcube inbox (SSO completed) or Keycloak
    // login form (credentials needed).
    const kc = '#username:visible, #mt-password, #passkey-login-btn';
    const result = await Promise.race([
      page.locator(ROUNDCUBE_INBOX).first().waitFor({ timeout: 45_000 }).then(() => 'inbox' as const),
      page.locator(kc).first().waitFor({ timeout: 45_000, state: 'attached' }).then(() => 'keycloak' as const),
    ]).catch(() => 'timeout' as const);

    if (result === 'inbox') {
      return; // SSO completed successfully
    }

    if (result === 'keycloak') {
      await keycloakLogin(page, username, password);
      await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 30_000 });
      return;
    }

    // Timeout — page may be stuck mid-redirect on Keycloak or showing an error.
    // On first attempt, retry the OAuth URL to give the redirect another chance.
    if (attempt === 0) {
      console.log('  [roundcube] OIDC redirect timed out, retrying...');
      continue;
    }

    // Second attempt also timed out — try one final wait for inbox
    await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 15_000 });
  }
}

// Uses emailTestPage (fixed user with persistent Stalwart mail principal)
// because pipeline-scoped users may not have Stalwart principals yet,
// causing OAUTHBEARER auth to fail during the Roundcube OIDC flow.
test.describe('Email — Roundcube Basic', () => {
  test('SSO login to Roundcube loads inbox', async ({ emailTestPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.emailTest.username, TEST_USERS.emailTest.password);

    await expect(
      page.locator(ROUNDCUBE_INBOX).first(),
    ).toBeVisible({ timeout: 30_000 });
  });

  test('keyboard shortcuts plugin is active', async ({ emailTestPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.emailTest.username, TEST_USERS.emailTest.password);

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

  test('calendar button links to Nextcloud Calendar', async ({ emailTestPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.emailTest.username, TEST_USERS.emailTest.password);

    // The nextcloud_calendar plugin adds a calendar button to the sidebar
    const calendarBtn = page.locator('#taskmenu a.button-calendar');
    await expect(calendarBtn).toBeAttached({ timeout: 10_000 });

    // Button should link to Nextcloud Calendar (not Roundcube's built-in calendar)
    const href = await calendarBtn.getAttribute('href');
    expect(href).toContain('/apps/calendar');

    // Should open in a new tab
    const target = await calendarBtn.getAttribute('target');
    expect(target).toBe('_blank');
  });

  test('can open compose form', async ({ emailTestPage: page }) => {
    await navigateToRoundcube(page, TEST_USERS.emailTest.username, TEST_USERS.emailTest.password);

    // Click compose button
    await page.locator('button:has-text("Compose"), a.compose, [data-command="compose"]').first().click();

    // Should see the compose form with To and Subject fields
    await expect(
      page.locator('#_to, #compose-subject, textarea#composebody').first(),
    ).toBeVisible({ timeout: 15_000 });
  });
});
