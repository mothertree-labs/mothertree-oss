import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { Page } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

/**
 * Handle Nextcloud login — completes the Keycloak OIDC flow when redirected.
 */
async function handleNextcloudLogin(page: Page): Promise<void> {
  if (page.url().includes('auth.')) {
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('networkidle').catch(() => {});
    return;
  }

  const onNativeLogin = page.url().includes('/login') &&
    !page.url().includes('user_oidc') &&
    await page.locator('input[name="password"], #password').isVisible({ timeout: 2_000 }).catch(() => false);

  if (onNativeLogin) {
    const oidcResponse = await page.goto(`${urls.files}/apps/user_oidc/login/1`, { timeout: 30_000 }).catch(() => null);
    if (!oidcResponse) return;
    await page.waitForLoadState('networkidle').catch(() => {});

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }
  }
}

test.describe('Smoke — Nextcloud Collabora (Office)', () => {
  test('Collabora discovery endpoint responds', async ({ memberPage: page }) => {
    if (!config.collaboraEnabled) {
      test.skip(true, 'Set collaboraEnabled: true in e2e.config.json');
    }

    const freshPage = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true }).then(ctx => ctx.newPage());

    const response = await freshPage.goto(`${urls.office}/hosting/discovery`).catch(() => null);
    const status = response?.status() ?? 0;
    await freshPage.close();

    if (!response) {
      test.skip(true, 'Collabora not reachable (DNS or connection error)');
    }

    expect(status, `Collabora discovery returned HTTP ${status}`).toBeLessThan(500);
  });

  test('opening a document loads Collabora iframe (WOPI flow)', async ({ memberPage: page }) => {
    test.setTimeout(120_000);

    if (!config.collaboraEnabled) {
      test.skip(true, 'Set collaboraEnabled: true in e2e.config.json');
    }

    // Verify Collabora is reachable before attempting the full flow
    const discoveryPage = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true }).then(ctx => ctx.newPage());
    const discoveryResponse = await discoveryPage.goto(`${urls.office}/hosting/discovery`).catch(() => null);
    await discoveryPage.close();
    if (!discoveryResponse) {
      test.skip(true, 'Collabora not reachable (DNS or connection error)');
    }

    // Step 1: Login to Nextcloud
    const response = await page.goto(`${urls.files}/apps/files/`).catch(() => null);
    if (!response) {
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
    }

    await page.waitForLoadState('networkidle').catch(() => {});
    await handleNextcloudLogin(page);
    await page.waitForLoadState('networkidle').catch(() => {});
    await page.waitForTimeout(3_000);

    // Verify we're logged in
    const hasContent = await page
      .locator('#app-content, .files-list, [class*="app-content"]')
      .first()
      .isVisible({ timeout: 15_000 })
      .catch(() => false);
    expect(hasContent, 'Nextcloud files view did not load after login').toBe(true);

    // Step 2: Upload a test .odt file via the hidden file input
    const testFileName = `e2e-collabora-test-${Date.now()}.odt`;
    const fileInput = page.locator('input[type="file"]');
    expect(await fileInput.count(), 'No file input found in Nextcloud').toBeGreaterThan(0);

    // Minimal .odt is a zip — but Nextcloud accepts any file.
    // We use a plain text file with .odt extension; Collabora will still attempt
    // to open it via WOPI, which is what we're testing.
    await fileInput.first().setInputFiles({
      name: testFileName,
      mimeType: 'application/vnd.oasis.opendocument.text',
      buffer: Buffer.from('E2E Collabora WOPI test'),
    });

    // Wait for upload
    await page.waitForTimeout(3_000);

    // Step 3: Click the uploaded file to open it in Collabora
    const fileRow = page.locator(`[data-cy-files-list] [data-cy-files-list-row-name="${testFileName}"], .files-list tr[data-file="${testFileName}"], a:has-text("${testFileName}")`);
    await fileRow.first().click({ timeout: 10_000 });

    // Step 4: Verify Collabora iframe loads
    // When richdocuments opens a file, it creates an iframe with id="richdocuments-frame"
    // pointing to the Collabora server. If WOPI CheckFileInfo fails (ECONNRESET),
    // the iframe won't load or will show an error.
    const collaboraFrame = page.locator('#richdocuments-frame, iframe[src*="cool.html"], iframe[src*="loleaflet"]');
    const frameLoaded = await collaboraFrame
      .first()
      .isVisible({ timeout: 30_000 })
      .catch(() => false);

    // Check for WOPI error messages that appear when CheckFileInfo fails
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasWopiError = /WOPI|wopi.*error|failed to read document|document loading failed/i.test(pageText);

    expect(hasWopiError, 'WOPI error detected — Collabora cannot reach Nextcloud (PROXY protocol issue)').toBe(false);
    expect(frameLoaded, 'Collabora iframe did not load — richdocuments failed to open document via WOPI').toBe(true);
  });
});
