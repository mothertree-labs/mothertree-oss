import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import * as fs from 'fs';
import * as path from 'path';
import * as https from 'https';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

const echoGroupAddress = process.env.E2E_ECHO_GROUP_ADDRESS || config.echoGroupAddress;
const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';

const ACCOUNT_PORTAL_URL = `https://account.${baseDomain}`;

const TEST_PGP_PUBLIC_KEY = `-----BEGIN PGP PUBLIC KEY BLOCK-----
mQENBF+4rWIBAATLAksQ7v0xN0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZ
wE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X
+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF
4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7
J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZ
wE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X
+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20E
EHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF
4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+
JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0
j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dIJPBZwE4X+Mi20EEHrF4n+JB0j7J3dI
JPBZw=
-----END PGP PUBLIC KEY BLOCK-----
`;

function httpsRequest(
  url: string,
  options: {
    method?: string;
    body?: object;
  }
): Promise<{ success?: boolean; error?: string }> {
  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(url);

    const requestOptions = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || 443,
      path: parsedUrl.pathname + parsedUrl.search,
      method: options.method || 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      rejectUnauthorized: false,
    };

    const req = https.request(requestOptions, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          reject(new Error(`Failed to parse response: ${data}`));
        }
      });
    });

    req.on('error', reject);

    if (options.body) {
      req.write(JSON.stringify(options.body));
    }
    req.end();
  });
}

async function roundcubeLogin(
  page: import('@playwright/test').Page,
  username: string,
  password: string
) {
  await page.goto(`${urls.webmail}/?_task=login&_action=oauth`);
  await page.waitForLoadState('networkidle');

  const onKeycloak = new URL(page.url()).hostname.startsWith('auth.');
  if (onKeycloak) {
    await keycloakLogin(page, username, password);
    await page.waitForLoadState('networkidle');
  }

  await page.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 30_000 });
}

test.describe('Email — Encryption at Rest', () => {
  test('enable encryption via account portal API, send email, verify delivery', async ({
    emailRecvPage,
  }) => {
    test.setTimeout(180_000);

    expect(
      echoGroupAddress,
      'Set E2E_ECHO_GROUP_ADDRESS env var'
    ).toBeTruthy();

    const receiver = TEST_USERS.emailRecv;

    console.log('  [crypto] Step 1: Enable encryption via account portal API');

    const initResult = await httpsRequest(`${ACCOUNT_PORTAL_URL}/api/admin/init-user-encryption`, {
      method: 'POST',
      body: {
        email: receiver.email,
        name: receiver.username,
        publicKey: TEST_PGP_PUBLIC_KEY,
      },
    });

    console.log('  [crypto] Init response:', JSON.stringify(initResult));

    expect(initResult.success, 'Failed to enable encryption: ' + initResult.error).toBe(true);

    console.log('  [crypto] Step 2: Send email to echo group via Roundcube');

    await roundcubeLogin(emailRecvPage, receiver.username, receiver.password);

    await emailRecvPage.waitForFunction(
      () => window.rcmail && window.rcmail.task === 'mail' && !window.rcmail.busy,
      { timeout: 30_000 }
    );
    await emailRecvPage.getByRole('button', { name: 'Compose' }).click();
    const subjectInput = emailRecvPage.getByRole('textbox', { name: 'Subject' });
    await subjectInput.waitFor({ timeout: 15_000 });

    const toInput = emailRecvPage.locator('.recipient-input input').first();
    await toInput.waitFor({ state: 'visible', timeout: 10_000 });
    await toInput.click();
    await toInput.pressSequentially(echoGroupAddress);
    await toInput.press('Enter');

    const subject = `E2E Encryption Test ${Date.now()}`;
    await subjectInput.fill(subject);

    const bodyFrame = emailRecvPage.frameLocator('iframe').first();
    await bodyFrame.locator('body').fill('E2E encryption at rest test');

    await emailRecvPage.getByRole('button', { name: 'Send' }).click();

    await emailRecvPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', {
      timeout: 30_000,
    });

    console.log('  [crypto] Step 3: Poll for email delivery');

    const maxWait = 120_000;
    const pollInterval = 5000;
    let found = false;
    const start = Date.now();

    while (Date.now() - start < maxWait) {
      const refreshed = await emailRecvPage
        .getByRole('button', { name: /refresh|check/i })
        .first()
        .click({ timeout: 3000 })
        .then(() => true)
        .catch(() => false);
      if (!refreshed) {
        await emailRecvPage.reload();
        await emailRecvPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', {
          timeout: 15000,
        });
      }
      await emailRecvPage.waitForTimeout(2000);

      const hasSubject = await emailRecvPage
        .locator(`td:has-text("${subject}")`)
        .first()
        .isVisible()
        .catch(() => false);

      if (hasSubject) {
        found = true;
        break;
      }

      await emailRecvPage.waitForTimeout(pollInterval);
    }

    expect(
      found,
      `Expected email with subject "${subject}" to appear in inbox`
    ).toBe(true);

    console.log('  [crypto] Test passed: email delivered');
  });
});