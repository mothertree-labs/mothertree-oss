import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { loginToApp, keycloakLogin } from '../../helpers/auth';
import { TEST_USERS } from '../../helpers/test-users';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

async function checkLLMAvailable(page: any): Promise<boolean> {
  if (config.llmEnabled === false) return false;
  const checkContext = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true });
  const checkPage = await checkContext.newPage();
  const response = await checkPage.goto(urls.llm).catch(() => null);
  await checkPage.close();
  await checkContext.close();
  return !!response;
}


test.describe('LLM', () => {
  test.setTimeout(120_000);

  test('login and verify default model is selected', async ({ memberPage: page }) => {
    const isAvailable = await checkLLMAvailable(page);
    if (!isAvailable) {
      test.skip(true, 'LLM service not reachable');
    }

    await page.setViewportSize({ width: 1280, height: 1080 });
    await loginToApp(page, urls.llm, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('load');

    // Handle SSO button if Open WebUI shows landing page instead of auto-redirecting
    // Check multiple times as page might still be loading
    for (let i = 0; i < 5; i++) {
      const ssoBtn = page.locator('button:has-text("Continue with SSO")');
      if (await ssoBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
        await ssoBtn.evaluate((el: HTMLElement) => el.click());
        await page.waitForLoadState('load');
        // After SSO click, may redirect to Keycloak
        if (page.url().includes('auth.')) {
          await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
          await page.waitForLoadState('load');
        }
        break;
      }
      await page.waitForTimeout(1000);
    }

    // Handle model selection onboarding dialog if it appears
    const dialog = page.locator('div[role="dialog"][aria-modal="true"]');
    for (let i = 0; i < 20; i++) {
      if (await dialog.isVisible().catch(() => false)) {
        await page.locator('button:has-text("Select a model")').click().catch(() => {});
        await page.waitForTimeout(500);
        await page.locator('li').first().click({ timeout: 3000 }).catch(() => {});
        await page.waitForTimeout(500);
        await page.locator('button:has-text("Set as default")').click({ timeout: 2000 }).catch(() => {});
        await page.waitForTimeout(2000);
        break;
      }
      await page.waitForTimeout(500);
    }

    await expect(page.locator('text=llama3.2:1b').first()).toBeVisible({ timeout: 10_000 });
  });
});
