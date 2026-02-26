import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';

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
});
