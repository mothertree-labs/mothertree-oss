import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import * as fs from 'fs';
import * as path from 'path';

// Load echo group config
const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

const echoGroupAddress = config.echoGroupAddress;

test.describe('Email — Round-Trip via Echo Group', () => {
  test.skip(!echoGroupAddress, 'Skipped: echoGroupAddress not configured in e2e.config.json');

  test('send email to echo group and receive bounce-back', async ({ emailTestPage: page }) => {
    const user = TEST_USERS.emailTest;

    // Navigate to Roundcube
    await page.goto(urls.webmail);
    await page.waitForLoadState('networkidle');

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
      await page.waitForLoadState('networkidle');
    }

    // Wait for Roundcube inbox to load
    await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });

    // Click compose
    await page.locator('a.compose, [data-command="compose"], .button.compose').first().click();
    await page.waitForSelector('input[name="_to"], #compose-to', { timeout: 15_000 });

    // Fill compose form
    const subject = `E2E Round-Trip Test ${Date.now()}`;
    await page.locator('input[name="_to"], #compose-to').first().fill(echoGroupAddress);
    await page.locator('input[name="_subject"], #compose-subject').first().fill(subject);

    // Type message body in the editor
    const bodyFrame = page.frameLocator('iframe[name="composebody"], iframe.mce-edit-area');
    const bodyInput = page.locator('textarea[name="_message"], #composebody');
    if (await bodyInput.isVisible()) {
      await bodyInput.fill('E2E round-trip test message');
    } else {
      await bodyFrame.locator('body').fill('E2E round-trip test message');
    }

    // Send the email
    await page.locator('a.send, [data-command="send"], .button.send').first().click();

    // Wait for send confirmation and return to inbox
    await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });

    // Poll inbox for the echo response (up to 2 minutes)
    const maxWait = 120_000;
    const pollInterval = 5_000;
    let found = false;
    const start = Date.now();

    while (Date.now() - start < maxWait) {
      // Refresh the inbox
      await page.locator('a.refresh, [data-command="checkmail"], .button.refresh').first().click();
      await page.waitForTimeout(2000);

      // Check if the echoed email appears in the message list
      const messageList = page.locator('#messagelist');
      const hasSubject = await messageList.locator(`text=${subject}`).isVisible().catch(() => false);

      if (hasSubject) {
        found = true;
        break;
      }

      await page.waitForTimeout(pollInterval);
    }

    expect(found).toBe(true);
  });
});
