import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { isImapConfigured } from '../../helpers/imap';
import * as fs from 'fs';
import * as path from 'path';
import * as https from 'https';

const configPath = path.join(__dirname, '..', '..', 'e2e.config.json');
const config = fs.existsSync(configPath)
  ? JSON.parse(fs.readFileSync(configPath, 'utf-8'))
  : {};

const echoGroupAddress = process.env.E2E_ECHO_GROUP_ADDRESS || config.echoGroupAddress;
const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const stalwartAdminPassword = process.env.E2E_STALWART_ADMIN_PASSWORD || config.stalwartAdminPassword;

const STALWART_API_URL = `https://mail.${baseDomain}`;

const TEST_PGP_PUBLIC_KEY = `-----BEGIN PGP PUBLIC KEY BLOCK-----

mQENBGnyOzUBCADPLRI3CExFwCyWyRQ34ljlnCwa9tii+XhB45Db7ESCrucUUgnM
+oUNekpY0kJMcLaveWnH0GFCBFMMkX644sWrBFO20LvhEYlzC9az7WcV/wl/MYs1
biYBAay7mkfOsDy6OC8HyqGDtPu6aLh2zh618LNwu7nRdlL5d+8/+gg8vSPHR1zO
VqnZJESjdLrSJrOdKwkZz7UNBQ6tre994WnUzmwSW/C6f87cf+q0tnqNh2qhQHEM
yO8psf/wYZwPupLKugV+iWU/rsk5J/wNJhsSHeHFgH8cp0fbDDri8Z01Ea3sidZx
AC3hN7c416hMfO1Y3iQJbk2Neu6JwMJuzmcfABEBAAG0HEUyRSBUZXN0IDxlMmUt
dGVzdEB0ZXN0LmNvbT6JAVIEEwEKADwWIQSvKKFNWpF26o3+orZKrM8y/MBk8gUC
afI7NQMbLwQFCwkIBwICIgIGFQoJCAsCBBYCAwECHgcCF4AACgkQSqzPMvzAZPIX
iwf9GJAcfhKwbBD7/li34NwLx71gokvmjBftvx3O4XfA4AI4JIPO3gS3Utg7AEzz
EGNKlBrOZ2qCdrXDqUTjUk68SYt5m9pIg24wM6xBzaE9moih4JduXzBVdbnmj5EE
NGcnhCb5q1zj48KSV6VXrImgvitw263ty5AGd/GzcSA3aS8HzIPIovtgao8IWMlt
LEDhKp9KAtj+XXWovrfEg+bGLrwSGcysHata6gAB9sU09OMVUoc9WLl66ut5ZsCu
1F0z361PA+KEqweGLSIVwaJ4x0UMru5HT4LlHN5051RaKvA474mCWN/SN25xLbzl
V/0aH45DOGJN/WbpAssESdXrXg==
=tpxP
-----END PGP PUBLIC KEY BLOCK-----
`;

function stalwartRequest(
  fullUrl: string,
  options: {
    method?: string;
    body?: object;
    auth?: string;
  }
): Promise<any> {
  return new Promise((resolve, reject) => {
    // Support both absolute URLs (for JMAP port) and relative paths (for API)
    const url = fullUrl.startsWith('http') ? new URL(fullUrl) : new URL(fullUrl, STALWART_API_URL);

    const authHeader = options.auth
      ? 'Basic ' + Buffer.from(options.auth).toString('base64')
      : undefined;

    const requestOptions = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname + url.search,
      method: options.method || 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(authHeader ? { Authorization: authHeader } : {}),
      },
      rejectUnauthorized: false,
    };

    const req = https.request(requestOptions, (res: any) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          resolve(data ? JSON.parse(data) : { status: res.statusCode });
        } catch {
          resolve({ status: res.statusCode, raw: data });
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
  test('enable encryption, send email via echo group, verify delivery', async ({
    emailTestPage: senderPage,
    emailRecvPage: receiverPage,
  }) => {
    test.setTimeout(180_000);

    expect(echoGroupAddress, 'Set E2E_ECHO_GROUP_ADDRESS env var').toBeTruthy();
    expect(stalwartAdminPassword, 'Set E2E_STALWART_ADMIN_PASSWORD env var').toBeTruthy();

    const sender = TEST_USERS.emailTest;
    const receiver = TEST_USERS.emailRecv;
    const adminAuth = `admin:${stalwartAdminPassword}`;

    // ── Step 1: Enable encryption for receiver ──
    console.log('  [crypto] Step 1: Log in as receiver to create Stalwart principal');
    await roundcubeLogin(receiverPage, receiver.username, receiver.password);

    const principalName = receiver.username;
    console.log(`  [crypto] Using principal name: ${principalName}`);

    // Poll for principal to appear in API
    let principalResult: any = { error: 'notFound' };
    for (let i = 0; i < 10; i++) {
      principalResult = await stalwartRequest(
        `/api/principal/${encodeURIComponent(principalName)}`,
        { method: 'GET', auth: adminAuth }
      );
      if (!principalResult.error) break;
      console.log(`  [crypto] Principal not found, retrying... (${i + 1}/10)`);
      await new Promise(r => setTimeout(r, 2000));
    }
    console.log('  [crypto] Principal response:', JSON.stringify(principalResult));
    expect(principalResult.error, 'Principal should exist after login').toBeUndefined();

    console.log('  [crypto] Step 2: Create app password for crypto API');
    const appPassword = `e2ecrypto${Date.now()}`;
    const appPasswordResult = await stalwartRequest(
      `/api/principal/${encodeURIComponent(principalName)}`,
      {
        method: 'PATCH',
        auth: adminAuth,
        body: [
          { action: 'addItem', field: 'secrets', value: `$app$crypto-test$${appPassword}` },
        ],
      }
    );
    console.log('  [crypto] App password result:', JSON.stringify(appPasswordResult));
    expect(appPasswordResult.error, 'App password creation should succeed').toBeUndefined();

    console.log('  [crypto] Step 3: Enable PGP encryption via /api/account/crypto');
    const encryptionResult = await stalwartRequest(
      `/api/account/crypto`,
      {
        method: 'POST',
        auth: `${principalName}:${appPassword}`,
        body: {
          type: 'pGP',
          algo: 'Aes256',
          certs: TEST_PGP_PUBLIC_KEY,
          allow_spam_training: true,
        },
      }
    );
    console.log('  [crypto] Encryption enable result:', JSON.stringify(encryptionResult));
    expect(encryptionResult.error, 'Should not have error enabling encryption').toBeUndefined();

    // ── Step 2: Sender sends email to echo group ──
    console.log('  [crypto] Step 4: Sender logs in and sends email to echo group');
    await roundcubeLogin(senderPage, sender.username, sender.password);

    await senderPage.waitForFunction(
      () => window.rcmail && window.rcmail.task === 'mail' && !window.rcmail.busy,
      { timeout: 30_000 },
    );
    await senderPage.getByRole('button', { name: 'Compose' }).click();

    const subjectInput = senderPage.getByRole('textbox', { name: 'Subject' });
    await subjectInput.waitFor({ timeout: 15_000 });

    const toInput = senderPage.locator('.recipient-input input').first();
    await toInput.waitFor({ state: 'visible', timeout: 10_000 });
    await toInput.click();
    await toInput.pressSequentially(echoGroupAddress);
    await toInput.press('Enter');

    const subject = `E2E Encryption Test ${Date.now()}`;
    await subjectInput.fill(subject);

    const bodyFrame = senderPage.frameLocator('iframe').first();
    await bodyFrame.locator('body').fill('E2E encryption at rest test');

    await senderPage.getByRole('button', { name: 'Send' }).click();
    await senderPage.waitForFunction(
      () => window.rcmail && window.rcmail.task === 'mail' && !window.rcmail.busy,
      { timeout: 30_000 },
    );

    // ── Step 3: Receiver polls for the forwarded email ──
    console.log('  [crypto] Step 5: Receiver polls for encrypted email in inbox');

    const maxWait = 120_000;
    const pollInterval = 5000;
    let found = false;
    const start = Date.now();

    while (Date.now() - start < maxWait) {
      const refreshed = await receiverPage
        .getByRole('button', { name: /refresh|check/i }).first()
        .click({ timeout: 3000 })
        .then(() => true)
        .catch(() => false);
      if (!refreshed) {
        await receiverPage.reload();
        await receiverPage.waitForSelector('#messagelist, #mailboxlist, .mailbox-list', { timeout: 15_000 });
      }
      await receiverPage.waitForTimeout(2000);

      const hasSubject = await receiverPage
        .locator(`td:has-text("${subject}")`).first()
        .isVisible()
        .catch(() => false);

      if (hasSubject) {
        found = true;
        break;
      }
      await receiverPage.waitForTimeout(pollInterval);
    }

    expect(found, `Expected email with subject "${subject}" to appear in inbox`).toBe(true);

    // ── Step 4: Verify email is encrypted (not plaintext) ──
    console.log('  [crypto] Step 6: Verify email body is encrypted (not plaintext)');
    await receiverPage.locator(`td:has-text("${subject}")`).first().click();
    await receiverPage.waitForTimeout(2000);

    const emailBody = await receiverPage
      .locator('#messagebody, .message-part, .mailvelope, iframe')
      .textContent({ timeout: 5000 })
      .catch(() => '');

    console.log('  [crypto] Email body preview:', emailBody.substring(0, 200));
    const isPlaintext = emailBody.includes('E2E encryption at rest test');
    console.log('  [crypto] Is plaintext:', isPlaintext);

    expect(isPlaintext, 'Email should NOT be plaintext when PGP encryption at rest is enabled').toBe(false);
    console.log('  [crypto] Test passed: email delivered and is encrypted at rest');
  });
});
