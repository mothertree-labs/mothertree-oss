import { Page } from '@playwright/test';
import { urls } from './urls';
import { keycloakLogin } from './auth';
import { TEST_USERS } from './test-users';

/**
 * Handle Nextcloud login — completes the Keycloak OIDC flow when redirected.
 * This should ONLY need to handle the Keycloak redirect case. If Nextcloud
 * shows its native login page, that's a configuration bug (allow_multiple_user_backends=1)
 * and the dedicated 'login redirects to Keycloak' test will catch it.
 */
export async function handleNextcloudLogin(page: Page): Promise<void> {
  if (page.url().includes('auth.')) {
    // Landed on Keycloak — complete the login flow
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('networkidle').catch(() => {});
    return;
  }

  // Check if we're on Nextcloud's native login page (not the app itself)
  const onNativeLogin = page.url().includes('/login') &&
    !page.url().includes('user_oidc') &&
    await page.locator('input[name="password"], #password').isVisible({ timeout: 2_000 }).catch(() => false);

  if (onNativeLogin) {
    // Trigger OIDC flow — navigate to the user_oidc login endpoint,
    // which redirects to Keycloak. The existing SSO session should auto-complete.
    // Use a timeout since this can hang when Nextcloud can't reach Keycloak.
    const oidcResponse = await page.goto(`${urls.files}/apps/user_oidc/login/1`, { timeout: 30_000 }).catch(() => null);

    if (!oidcResponse) {
      // OIDC endpoint timed out — Nextcloud can't reach Keycloak, nothing we can do
      return;
    }

    await page.waitForLoadState('networkidle').catch(() => {});

    // If Keycloak session expired, we'll land on the Keycloak login page
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }
  }
}

/**
 * Wait for Nextcloud to be ready after login, handling maintenance mode.
 *
 * During HPA scale-up or upgrades, Nextcloud may be in maintenance mode
 * (occ upgrade sets maintenance=true in the shared DB). This function:
 * 1. Checks status.php for maintenance/needsDbUpgrade flags
 * 2. Retries with reload if Nextcloud is temporarily unavailable
 * 3. Waits for the files view to be visible
 */
export async function waitForNextcloudReady(
  page: Page,
  options?: { timeout?: number },
): Promise<void> {
  const selectorTimeout = options?.timeout ?? 30_000;
  const maxRetries = 4;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    // Check status.php from within the browser context (uses existing cookies, avoids CORS)
    const status = await page.evaluate(async (filesUrl: string) => {
      try {
        const resp = await fetch(`${filesUrl}/status.php`);
        return await resp.json();
      } catch {
        return null;
      }
    }, urls.files).catch(() => null);

    const inMaintenance = status?.maintenance === true;
    const needsUpgrade = status?.needsDbUpgrade === true;

    if (!inMaintenance && !needsUpgrade) {
      break;
    }

    if (attempt === maxRetries) {
      // Last attempt — fall through and let the selector wait fail with a clear message
      console.log(`[waitForNextcloudReady] Still in maintenance after ${maxRetries} attempts, proceeding anyway`);
      break;
    }

    console.log(
      `[waitForNextcloudReady] Nextcloud maintenance=${inMaintenance} needsDbUpgrade=${needsUpgrade}, ` +
      `retrying in 10s (attempt ${attempt}/${maxRetries})`,
    );
    await page.waitForTimeout(10_000);
    await page.reload().catch(() => {});
    await page.waitForLoadState('networkidle').catch(() => {});
  }

  // Wait for the files view to appear
  await page.waitForSelector(
    '#app-content, .files-list, [class*="app-content"]',
    { timeout: selectorTimeout },
  );
}
