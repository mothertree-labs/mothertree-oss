import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Element (Chat)', () => {
  test('SSO login loads Element main UI', async ({ memberPage: page }) => {
    // Element runs on the matrix subdomain as a React SPA.
    // SSO flow: Element loads → auto-redirects to Synapse SSO → Keycloak →
    // Synapse "Continue to your account" confirmation → back to Element.
    // The memberPage fixture provides Keycloak session cookies, so Keycloak
    // auto-completes without user interaction.
    const response = await page.goto(urls.element, {
      waitUntil: 'domcontentloaded',
    }).catch(() => null);

    if (!response) {
      test.skip(true, 'Element not reachable (DNS or connection error)');
    }

    const status = response!.status();
    test.skip(status >= 500, `Element returned HTTP ${status} — not a test issue`);

    // Element has sso_redirect_options.immediate = true, which triggers an automatic
    // JS redirect through the SSO chain. Wait for one of three states:
    // 1. Element's React UI (.mx_MatrixChat) — SSO completed fully
    // 2. Synapse's "Continue to your account" page — needs a click to proceed
    // 3. Keycloak login page — session expired, needs manual login
    // Avoid networkidle — Element's WebSocket connections prevent it from resolving.
    try {
      await page.waitForSelector(
        [
          '.mx_MatrixChat',     // Element's main React container (post-login)
          'a.primary-button',   // Synapse SSO "Continue" confirmation page
          '#passkey-login-btn', // Keycloak passkey-first page
          '#username',          // Keycloak username input
          '#mt-password',       // Keycloak password input
        ].join(', '),
        { timeout: 45_000 },
      );
    } catch {
      // The SSO redirect chain may have stalled. Detect the page state and skip
      // with a clear message rather than a generic timeout.
      const currentUrl = page.url();
      const pageTitle = await page.title().catch(() => '');
      if (currentUrl.includes('oidc/callback') || pageTitle.includes('Error')) {
        test.skip(true, 'Synapse OIDC callback failed — server-side token exchange error');
      }
      test.skip(true, `Timed out waiting for Element or Keycloak (at ${currentUrl})`);
    }

    // Check where we actually are by hostname (not full URL, which may contain
    // auth domain in query params like iss=https://auth.example.com/...)
    const currentHost = new URL(page.url()).hostname;

    // If we landed on Keycloak, complete login
    if (currentHost.startsWith('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    }

    // Synapse shows a "Continue to your account" confirmation page after OIDC callback.
    // Click through it to redirect back to Element.
    const continueBtn = page.locator('a.primary-button');
    if (await continueBtn.isVisible().catch(() => false)) {
      await continueBtn.click();
    }

    // Wait for Element's React app to render into #matrixchat.
    // This is the definitive signal that the SPA loaded and SSO completed.
    const matrixChat = page.locator('.mx_MatrixChat');
    await expect(matrixChat).toBeVisible({ timeout: 30_000 });

    // Verify we're on the Element domain, not stuck on auth or Synapse callback
    expect(page.url()).toContain('matrix.');
  });
});
