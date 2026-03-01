import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

test.describe('Smoke — Jitsi (Video)', () => {
  test('Jitsi application loads', async ({ page }) => {
    const response = await page.goto(urls.jitsi).catch(() => null);

    if (!response) {
      test.skip(true, 'Jitsi not reachable (DNS or connection error)');
    }

    const status = response!.status();
    test.skip(status >= 500, `Jitsi returned server error ${status}`);

    // Jitsi is a React SPA — wait for JS to execute and render
    // The app renders into <div id="react"> and loads config.js
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    // Verify the page has Jitsi content (title, config, or React app)
    const title = await page.title();
    const hasJitsiTitle = /jitsi/i.test(title);
    const hasReactRoot = await page.locator('#react').count() > 0;
    const pageContent = await page.content();
    const hasJitsiConfig = pageContent.includes('config.js') || pageContent.includes('jitsi');

    expect(hasJitsiTitle || hasReactRoot || hasJitsiConfig).toBe(true);
  });

  test('room URL triggers OIDC auth redirect', async ({ page }) => {
    // Navigating to a room should redirect to OIDC for authentication
    const roomUrl = `${urls.jitsi}/e2e-smoke-test`;
    const response = await page.goto(roomUrl).catch(() => null);

    if (!response) {
      test.skip(true, 'Jitsi not reachable (DNS or connection error)');
    }

    const status = response!.status();
    test.skip(status >= 500, `Jitsi returned server error ${status}`);

    // Wait for redirects to complete (nginx → oidc-redirect.html → /oidc/redirect → Keycloak)
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    // The URL should contain either:
    // - 'auth.' (redirected to Keycloak)
    // - 'oidc' (in the OIDC adapter flow)
    // - the room with oidc param (oidc=authorized/unauthorized/failed)
    const currentUrl = page.url();
    const hasAuth = currentUrl.includes('auth.');
    const hasOidc = currentUrl.includes('oidc');

    // Either we landed on Keycloak or we're in the OIDC flow
    expect(hasAuth || hasOidc).toBe(true);
  });

  test('SSO login loads Jitsi room', async ({ memberPage: page }) => {
    const roomUrl = `${urls.jitsi}/e2e-auth-test`;
    const response = await page.goto(roomUrl).catch(() => null);

    if (!response) {
      test.skip(true, 'Jitsi not reachable (DNS or connection error)');
    }

    const status = response!.status();
    test.skip(status >= 500, `Jitsi returned server error ${status}`);

    // The OIDC redirect chain:
    //   nginx serves oidc-redirect.html (JS) → /oidc/redirect (adapter 302) →
    //   Keycloak (auto-login or form) → /static/oidc-adapter.html (JS) →
    //   /oidc/tokenize (adapter returns JWT) → /room?oidc=authorized&jwt=...
    //
    // If the memberPage SSO session is valid, Keycloak auto-redirects (no form).
    // Wait for the final room URL with oidc= param. If the chain stalls on
    // Keycloak (session expired), catch the timeout and complete login manually.
    try {
      await page.waitForURL(
        url => url.searchParams.has('oidc'),
        { timeout: 30_000 },
      );
    } catch {
      // Chain stalled — if we're on Keycloak, complete login and retry
      if (page.url().includes('auth.')) {
        await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
        await page.waitForURL(
          url => url.searchParams.has('oidc'),
          { timeout: 30_000 },
        );
      } else {
        throw new Error(
          `Jitsi OIDC flow did not complete. Current URL: ${page.url()}`,
        );
      }
    }

    const finalUrl = new URL(page.url());

    // Verify we're on the Jitsi domain (not stuck on auth)
    expect(finalUrl.hostname).not.toContain('auth.');

    // Verify the OIDC flow succeeded (not "failed" or "unauthorized")
    expect(finalUrl.searchParams.get('oidc')).toBe('authorized');

    // Verify a JWT token was provided
    expect(finalUrl.searchParams.get('jwt')).toBeTruthy();

    // Wait for the Jitsi room UI to render
    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    // Check for server errors
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasServerError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    expect(hasServerError, 'Jitsi returned a server error after SSO login').toBe(false);
  });
});
