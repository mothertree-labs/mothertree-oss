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

    // Wait for upload to complete and file to appear in the list
    const fileRow = page.locator(`[data-cy-files-list-row-name="${testFileName}"]`);
    await fileRow.waitFor({ state: 'visible', timeout: 15_000 });

    // Step 3: Click the uploaded file's name link to open it in Collabora.
    // Must click the name link specifically — clicking other parts of the row
    // just selects the file without opening it.
    const fileNameLink = fileRow.locator('.files-list__row-name-link');
    await fileNameLink.click({ timeout: 10_000 });

    // Step 4: Verify Collabora iframe loads
    // richdocuments 9.x creates an iframe with data-cy="coolframe" and a dynamic
    // id like "collaboraframe_<random>". The iframe starts hidden (visibility: hidden)
    // and becomes visible once cool.html loads and sends Frame_Ready.
    // Use waitFor + expect (auto-retrying) — isVisible() returns immediately without waiting.
    const collaboraFrame = page.locator('iframe[data-cy="coolframe"]');
    try {
      await collaboraFrame.first().waitFor({ state: 'visible', timeout: 30_000 });
    } catch {
      // Dump diagnostic info on failure
      const iframes = await page.evaluate(() =>
        Array.from(document.querySelectorAll('iframe')).map(f => ({
          id: f.id, dataCy: f.getAttribute('data-cy'),
          visible: f.offsetParent !== null, style: f.getAttribute('style'),
        }))
      );
      const hasViewer = await page.evaluate(() => !!document.querySelector('.office-viewer'));
      const pageText = await page.locator('body').textContent().catch(() => '') || '';
      const hasWopiError = /WOPI|wopi.*error|failed to read document|document loading failed/i.test(pageText);
      console.log(`[collabora] Frame not loaded. URL: ${page.url()}`);
      console.log(`[collabora] office-viewer present: ${hasViewer}`);
      console.log(`[collabora] iframes:`, JSON.stringify(iframes));

      expect(hasWopiError, 'WOPI error detected — Collabora cannot reach Nextcloud (PROXY protocol issue)').toBe(false);
      expect(false, 'Collabora iframe did not load — richdocuments failed to open document via WOPI').toBe(true);
    }
  });
});
