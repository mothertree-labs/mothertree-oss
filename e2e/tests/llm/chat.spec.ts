import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { keycloakLogin } from '../../helpers/auth';
import { TEST_USERS } from '../../helpers/test-users';
import * as fs from 'fs';
import * as path from 'path';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

/**
 * Check if LLM is configured and reachable.
 * Skips tests if LLM is not enabled in the config or if the endpoint doesn't respond.
 */
async function checkLLMAvailable(page: any): Promise<boolean> {
  // Check if LLM is explicitly disabled in config
  if (config.llmEnabled === false) {
    return false;
  }

  // Try to reach the LLM endpoint
  const checkContext = await page.context().browser()!.newContext({ ignoreHTTPSErrors: true });
  const checkPage = await checkContext.newPage();
  const response = await checkPage.goto(urls.llm).catch(() => null);
  await checkPage.close();
  await checkContext.close();

  // Consider it available if we get any response (even 401/403 means the service is up)
  return !!response;
}

/**
 * Navigate to the LLM UI and authenticate via Open WebUI's SSO flow.
 *
 * Open WebUI presents its own login page with a "Continue with SSO"
 * button rather than auto-redirecting to Keycloak. This helper clicks
 * that button, then completes the Keycloak OIDC flow if needed.
 */
async function loginToLLM(page: any): Promise<void> {
  await page.setViewportSize({ width: 1280, height: 1080 });

  await page.goto(urls.llm);
  await page.waitForLoadState('load');

  if (page.url().includes('auth.')) {
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('load');
  }

  // Open WebUI login page — click the SSO button
  const ssoButton = page.locator(selectors.llm.ssoButton);
  await ssoButton.waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {});
  if (await ssoButton.isVisible()) {
    // The button may be inside a scrollable container; use evaluate to dispatch click
    await ssoButton.evaluate((el: HTMLElement) => {
      el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    });
    await page.waitForURL(/(auth\.|\/c\/)/, { timeout: 15_000 }).catch(() => {});
  }

  // If redirected to Keycloak, complete login
  if (page.url().includes('auth.')) {
    await keycloakLogin(page, TEST_USERS.member.username, TEST_USERS.member.password);
    await page.waitForLoadState('load');
  }

  // Wait for the chat UI to be ready.
  // The SPA has a race: chat input renders, then model selection onboarding
  // may appear on top of it. Handle both cases with a simple sequential approach.
  const chatInput = page.locator(selectors.llm.chatInput);
  try {
    await expect(chatInput).toBeVisible({ timeout: 30_000 });
  } catch {
    // Chat input not visible after 30s — onboarding is likely showing.
    // Dismiss it by selecting a model and setting it as default.
    await page.locator('button:has-text("Select a model")').click().catch(() => {});
    await page.waitForTimeout(500);
    await page.locator('button:has-text("llama3.2")').first().click({ timeout: 3000 }).catch(() => {});
    await page.waitForTimeout(500);
    await page.locator('button:has-text("Set as default")').click({ timeout: 2000 }).catch(() => {});
    await page.waitForTimeout(2000);
    await expect(chatInput).toBeVisible({ timeout: 30_000 });
  }

  // After model is set, Open WebUI may redirect to a "Start chatting" page
  try {
    await page.waitForSelector('a:has-text("Start chatting"), button:has-text("Start chatting")', { timeout: 5000 });
    await page.locator('a:has-text("Start chatting"), button:has-text("Start chatting")').first().click({ force: true });
    await page.waitForLoadState('networkidle');
  } catch {
    // Already on the chat page
  }
}

/**
 * E2E tests for the LLM Chat UI (Open WebUI).
 *
 * These tests validate:
 * - Authentication via Keycloak OIDC
 * - Basic chat interaction (send message, receive response)
 * - Message display in the UI
 */
test.describe('LLM Chat UI', () => {
  test.setTimeout(240_000); // 4 minutes total timeout for SSO login + LLM inference

  test('smoke test: send message and receive response', async ({ memberPage: page }) => {
    // Check if LLM is available before running the test
    const isAvailable = await checkLLMAvailable(page);
    if (!isAvailable) {
      test.skip(true, 'LLM service not reachable — skipping test');
    }

    await loginToLLM(page);

    // Wait for chat input to be visible
    const chatInput = page.locator(selectors.llm.chatInput);
    await expect(chatInput).toBeVisible({ timeout: 15_000 });

    const testQuestion = 'What is the capital of France?';

    // Type into the TipTap editor using keyboard events
    await chatInput.click();
    await page.keyboard.type(testQuestion);
    await page.waitForTimeout(500);

    // Find and click the send button. Open WebUI 0.9.6 may use an icon button.
    // Try several selectors for the send button.
    const sendBtnSelectors = [
      'button[type="submit"]',
      'button[aria-label="Send"]',
      'button:has-text("Send")',
      'button svg[data-icon="send"]',
      'form button:last-child',
      '#chat-input ~ button, [data-testid="send-button"]',
    ];
    let sendBtn = null;
    for (const sel of sendBtnSelectors) {
      const btn = page.locator(sel).first();
      if (await btn.isVisible({ timeout: 1000 }).catch(() => false)) {
        sendBtn = btn;
        break;
      }
    }

    if (sendBtn) {
      await sendBtn.click();
    } else {
      await page.keyboard.press('Enter');
    }

    await page.waitForTimeout(3000);

    // Wait for user message to appear in chat
    const userMessageEl = page.locator(selectors.llm.userMessage).first();
    await expect(userMessageEl).toBeVisible({ timeout: 15_000 });

    // Wait for assistant response to appear (this is the main assertion)
    const assistantResponse = page.locator(selectors.llm.assistantMessage).first();
    await expect(assistantResponse).toBeVisible({ timeout: 120_000 });

    // Verify response has content
    const responseText = await assistantResponse.textContent();
    expect(responseText).toBeTruthy();
    expect(responseText?.length).toBeGreaterThan(0);
  });

  test('authentication: OIDC redirect works', async ({ memberPage: page }) => {
    // Check if LLM is available before running the test
    const isAvailable = await checkLLMAvailable(page);
    if (!isAvailable) {
      test.skip(true, 'LLM service not reachable — skipping test');
    }

    await loginToLLM(page);

    // Verify we're on the LLM UI
    // Check for chat input element
    const chatInput = page.locator(selectors.llm.chatInput);
    await expect(chatInput).toBeVisible({ timeout: 15_000 });
  });

  test('chat input: verify user message appears in history', async ({ memberPage: page }) => {
    // Check if LLM is available before running the test
    const isAvailable = await checkLLMAvailable(page);
    if (!isAvailable) {
      test.skip(true, 'LLM service not reachable — skipping test');
    }

    await loginToLLM(page);

    // Wait for chat input
    const chatInput = page.locator(selectors.llm.chatInput);
    await expect(chatInput).toBeVisible({ timeout: 15_000 });

    // Send a message
    const testMessage = 'Hello from E2E test';
    await chatInput.click();
    await page.keyboard.type(testMessage);

    const sendButton = page.locator(selectors.llm.sendButton);
    if (await sendButton.isVisible()) {
      await sendButton.click();
    } else {
      await page.keyboard.press('Enter');
    }

    // Wait for user message to appear in chat history
    const userMessages = page.locator(selectors.llm.userMessage);
    await expect(userMessages.first()).toBeVisible({ timeout: 10_000 });

    // Verify the message text appears somewhere in the chat
    const pageContent = await page.locator('body').textContent();
    expect(pageContent).toContain(testMessage);
  });
});
