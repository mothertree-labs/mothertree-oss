import type { Page } from '@playwright/test';
import { urls } from './urls';
import { keycloakLogin } from './auth';
import { captureRoundcubeStuckState } from './roundcube-failure';

/**
 * Selectors that prove the Roundcube inbox has rendered (any one is enough).
 * Shared so every caller waits on the same "logged-in" signal.
 */
export const ROUNDCUBE_INBOX =
  '#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")';

/**
 * Log into Roundcube via the OIDC flow and wait until the inbox has rendered.
 *
 * Deliberately does NOT use `page.waitForLoadState('networkidle')`. Roundcube
 * keeps background network activity going (keep-alive ping / inbox refresh), so
 * the network never goes idle for the 500ms `networkidle` requires — it times
 * out intermittently EVEN WHEN the OIDC login already succeeded server-side.
 * Observed on shard-5 pipeline #1597: roundcube logged `Successful login for
 * e2e-mailrcv` (the receiver), zero `Failed login` anywhere, yet the test still
 * failed on `networkidle`. Instead we race the inbox selector against the
 * Keycloak login form and resolve as soon as either is present — the same
 * robust pattern that keeps `roundcube-basic` green.
 *
 * `label` distinguishes call sites in the on-failure `[roundcube-stuck:*]` log
 * (e.g. `roundtrip-sender` vs `roundtrip-receiver`).
 *
 * Best-effort failure capture: on timeout it records WHERE the browser got
 * stuck (Keycloak vs. webmail-no-inbox) before re-throwing, so it never masks
 * the real assertion.
 */
export async function roundcubeOidcLogin(
  page: Page,
  username: string,
  password: string,
  label = 'roundcube',
): Promise<void> {
  try {
    // One retry for a transient mid-redirect hiccup.
    for (let attempt = 0; attempt < 2; attempt++) {
      await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);

      // Race: inbox (SSO already valid) vs. Keycloak login form (creds needed).
      const kc = '#username:visible, #mt-password, #passkey-login-btn';
      const result = await Promise.race([
        page
          .locator(ROUNDCUBE_INBOX)
          .first()
          .waitFor({ timeout: 45_000 })
          .then(() => 'inbox' as const),
        page
          .locator(kc)
          .first()
          .waitFor({ timeout: 45_000, state: 'attached' })
          .then(() => 'keycloak' as const),
      ]).catch(() => 'timeout' as const);

      if (result === 'inbox') {
        return; // SSO completed — inbox is up.
      }

      if (result === 'keycloak') {
        await keycloakLogin(page, username, password);
        await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 30_000 });
        return;
      }

      // Timeout: page may be stuck mid-redirect on Keycloak. Retry once.
      if (attempt === 0) {
        console.log('  [roundcube] OIDC redirect timed out, retrying...');
        continue;
      }

      // Second attempt also timed out — final wait for the inbox to surface.
      await page.waitForSelector(ROUNDCUBE_INBOX, { timeout: 15_000 });
    }
  } catch (err) {
    await captureRoundcubeStuckState(page, label);
    throw err;
  }
}
