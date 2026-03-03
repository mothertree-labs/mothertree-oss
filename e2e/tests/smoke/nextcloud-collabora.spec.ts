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

    // Step 2: Upload a test .odt file using the real upload UI flow.
    // Click New → Upload files → provide file via the native file chooser dialog.
    // Using setInputFiles on a hidden input doesn't trigger NC's Vue uploader.
    const testFileName = `e2e-wopi-${Date.now()}.odt`;

    // Delete the test file via WebDAV when the test ends (pass or fail).
    const deleteTestFile = async () => {
      await page.evaluate(async (name) => {
        const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
        await fetch('/remote.php/dav/files/' + OC.currentUser + '/' + name, {
          method: 'DELETE',
          headers: { 'requesttoken': token },
        }).catch(() => {});
      }, testFileName).catch(() => {});
    };

    try {
      // Open the "New" menu and click "Upload files", intercepting the file chooser.
      // This is the real user flow: click +New → Upload files → pick a file.
      const newButton = page.locator('form[data-cy-upload-picker] button').first();
      await newButton.click({ timeout: 10_000 });

      const uploadMenuItem = page.getByRole('menuitem', { name: 'Upload files' });
      await uploadMenuItem.waitFor({ state: 'visible', timeout: 5_000 });

      const [fileChooser] = await Promise.all([
        page.waitForEvent('filechooser'),
        uploadMenuItem.click(),
      ]);

      await fileChooser.setFiles({
        name: testFileName,
        mimeType: 'application/vnd.oasis.opendocument.text',
        buffer: Buffer.from('E2E Collabora WOPI test'),
      });

      // Wait for the upload to finish, then reload the file list. NC32's Vue
      // file list doesn't always reflect uploads triggered via the fileChooser
      // API. A reload guarantees the server-side file appears in the DOM.
      await page.waitForTimeout(3_000);
      await page.goto(`${urls.files}/apps/files/`);
      await page.waitForLoadState('networkidle').catch(() => {});

      const fileRow = page.locator(`[data-cy-files-list-row-name="${testFileName}"]`);
      await fileRow.waitFor({ state: 'visible', timeout: 15_000 });

      // Step 3: Click the uploaded file's name link to open it in Collabora.
      // Must click the name link specifically — clicking other parts of the row
      // just selects the file without opening it.
      const fileNameLink = fileRow.locator('.files-list__row-name-link');
      await fileNameLink.click({ timeout: 10_000 });

      // Step 4: Verify Collabora iframe loads.
      // richdocuments 9.x creates an iframe with data-cy="coolframe" and a dynamic
      // id like "collaboraframe_<random>". The iframe starts hidden (visibility: hidden)
      // and becomes visible once cool.html loads and sends Frame_Ready.
      const collaboraFrame = page.locator('iframe[data-cy="coolframe"]');
      await collaboraFrame.first().waitFor({ state: 'visible', timeout: 30_000 });
    } finally {
      await deleteTestFile();
    }
  });
});
