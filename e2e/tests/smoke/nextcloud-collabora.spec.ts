import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

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

    // Verify we're logged in (retries if Nextcloud is in maintenance mode during HPA scale-up)
    await waitForNextcloudReady(page, { timeout: 15_000 });

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
      // Step 2: Upload via WebDAV — deterministic and verifiable, unlike the
      // filechooser UI which fails consistently in headless CI.
      // This test is about Collabora/WOPI, not the Nextcloud upload UI.
      const uploadStatus = await page.evaluate(async (name) => {
        const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
        const resp = await fetch('/remote.php/dav/files/' + OC.currentUser + '/' + name, {
          method: 'PUT',
          headers: {
            'requesttoken': token,
            'Content-Type': 'application/vnd.oasis.opendocument.text',
          },
          body: 'E2E Collabora WOPI test',
        });
        return resp.status;
      }, testFileName);

      expect(uploadStatus, `WebDAV PUT returned HTTP ${uploadStatus}, expected 2xx`).toBeLessThan(300);

      // Navigate to the Recent view — the just-uploaded file appears at the top.
      // The default "All files" view sorts by name ascending and uses virtual
      // scrolling, so the file may be below the fold if the CI user has many
      // accumulated files from previous test runs.
      await page.goto(`${urls.files}/apps/files/recent`);
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
