import { test, expect } from '../../fixtures/authenticated';
import { selectors } from '../../helpers/selectors';
import { urls } from '../../helpers/urls';

test.describe('Account Portal — Home Dashboard', () => {
  test('displays app grid with expected cards', async ({ memberPage: page }) => {
    const ap = selectors.accountPortal;

    // Core app cards should be visible
    await expect(page.locator(ap.appCardChat)).toBeVisible();
    await expect(page.locator(ap.appCardDocs)).toBeVisible();
    await expect(page.locator(ap.appCardFiles)).toBeVisible();
    await expect(page.locator(ap.appCardDevicePasswords)).toBeVisible();
  });

  test('app cards link to correct domains', async ({ memberPage: page }) => {
    // Chat card links to matrix. subdomain (Element Web is served from there)
    const chatLink = await page.locator(selectors.accountPortal.appCardChat).getAttribute('href');
    expect(chatLink).toContain(urls.baseDomain);

    const docsLink = await page.locator(selectors.accountPortal.appCardDocs).getAttribute('href');
    expect(docsLink).toContain(`docs.${urls.baseDomain}`);

    const filesLink = await page.locator(selectors.accountPortal.appCardFiles).getAttribute('href');
    expect(filesLink).toContain(`files.${urls.baseDomain}`);
  });

  test('device passwords link navigates to app-passwords page', async ({ memberPage: page }) => {
    await page.click(selectors.accountPortal.appCardDevicePasswords);
    await expect(page).toHaveURL(/\/app-passwords/);
    await expect(page.locator(selectors.accountPortal.devicePasswordHeading)).toBeVisible();
  });
});
