import { test as base, Page, BrowserContext } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';
import { keycloakLogin } from '../helpers/auth';
import { TEST_USERS } from '../helpers/test-users';
import { urls } from '../helpers/urls';

const AUTH_DIR = path.join(__dirname, '..', '.auth');
const MAX_RETRIES = 5;
const RETRY_DELAY_MS = 10_000;

type AuthFixtures = {
  adminPage: Page;
  memberPage: Page;
  emailTestPage: Page;
};

/**
 * Tracks which roles have been validated in this process.
 * First call for each role validates against the server, subsequent calls
 * trust the saved state file. This avoids wasting HTTP requests on
 * validation while still catching stale cookies (e.g., after pod restarts).
 */
const validatedRoles = new Set<string>();

/**
 * Portal configuration per role.
 */
const ROLE_PORTAL: Record<keyof typeof TEST_USERS, {
  loginUrl: string;
  validationUrl: string;
  validationSelector: string;
}> = {
  admin: {
    loginUrl: `${urls.adminPortal}/auth/login`,
    validationUrl: urls.adminPortal,
    validationSelector: 'h1:has-text("mothertree admin")',
  },
  member: {
    loginUrl: `${urls.accountPortal}/auth/login`,
    validationUrl: `${urls.accountPortal}/home`,
    validationSelector: 'h1:has-text("Welcome,")',
  },
  emailTest: {
    loginUrl: `${urls.accountPortal}/auth/login`,
    validationUrl: `${urls.accountPortal}/home`,
    validationSelector: 'h1:has-text("Welcome,")',
  },
};

/**
 * Wait for a page to not be rate-limited.
 * Returns true if page is usable, false if still rate-limited after retries.
 */
async function waitForRateLimit(page: Page, url: string): Promise<boolean> {
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    const bodyText = await page.locator('body').textContent().catch(() => '');
    if (!bodyText?.includes('Too many requests')) {
      return true;
    }
    console.log(`  [auth] Rate limited, waiting ${RETRY_DELAY_MS}ms (attempt ${attempt + 1}/${MAX_RETRIES})...`);
    await page.waitForTimeout(RETRY_DELAY_MS);
    await page.goto(url);
    await page.waitForLoadState('load');
  }
  return false;
}

/**
 * Creates a page with a stored Keycloak session for the given user role.
 *
 * Strategy:
 * - First call per role per process: validates saved cookies against the server.
 *   If valid, marks the role as validated. If expired, performs fresh login.
 * - Subsequent calls: trusts the saved state file without making HTTP requests.
 *   This keeps requests minimal (1 per role per suite run).
 */
async function getAuthenticatedPage(
  context: BrowserContext,
  role: keyof typeof TEST_USERS,
): Promise<Page> {
  const stateFile = path.join(AUTH_DIR, `${role}.json`);
  const user = TEST_USERS[role];
  const portal = ROLE_PORTAL[role];

  // If already validated in this process, trust the saved state
  // Navigate to the portal so the page is in a usable state
  if (validatedRoles.has(role) && fs.existsSync(stateFile)) {
    const newContext = await context.browser()!.newContext({
      storageState: stateFile,
      ignoreHTTPSErrors: true,
    });
    const page = await newContext.newPage();
    await page.goto(portal.validationUrl);
    await page.waitForLoadState('load');

    // For admin portal, the landing page shows "Sign In" — click through
    if (role === 'admin') {
      const signInLink = page.locator('a[href="/auth/login"]');
      if (await signInLink.isVisible({ timeout: 2000 }).catch(() => false)) {
        await signInLink.click();
        await page.waitForLoadState('load');
      }
    }

    return page;
  }

  // First call for this role — validate the saved state
  if (fs.existsSync(stateFile)) {
    const newContext = await context.browser()!.newContext({
      storageState: stateFile,
      ignoreHTTPSErrors: true,
    });
    const page = await newContext.newPage();

    await page.goto(portal.validationUrl);
    await page.waitForLoadState('load');

    // Handle rate limiting
    if (!(await waitForRateLimit(page, portal.validationUrl))) {
      console.log(`  [auth] Rate limited during validation for ${role}, re-authenticating...`);
      await page.close();
      await newContext.close();
      // Fall through to fresh login
    } else {
      // For admin portal, click Sign In if on landing page
      if (role === 'admin') {
        const signInLink = page.locator('a[href="/auth/login"]');
        if (await signInLink.isVisible({ timeout: 2000 }).catch(() => false)) {
          await signInLink.click();
          await page.waitForLoadState('load');
        }
      }

      const isValid = await page.locator(portal.validationSelector).isVisible({ timeout: 5000 }).catch(() => false);
      if (isValid) {
        validatedRoles.add(role);
        // Refresh the state file
        await newContext.storageState({ path: stateFile });
        return page;
      }
      // Session expired — fall through to re-authenticate
      await page.close();
      await newContext.close();
    }
  }

  // Perform fresh login
  const newContext = await context.browser()!.newContext({
    ignoreHTTPSErrors: true,
  });
  const page = await newContext.newPage();

  await page.goto(portal.loginUrl);
  await page.waitForLoadState('load');

  // Handle rate limiting
  if (!(await waitForRateLimit(page, portal.loginUrl))) {
    throw new Error(`Rate limited by portal after ${MAX_RETRIES} retries for role ${role}`);
  }

  // Should now be on Keycloak login page
  if (page.url().includes('auth.')) {
    await keycloakLogin(page, user.username, user.password);
  }

  // Wait for the portal to load after OIDC callback
  await page.waitForSelector(portal.validationSelector, { timeout: 15_000 });

  // Save storage state for reuse
  if (!fs.existsSync(AUTH_DIR)) {
    fs.mkdirSync(AUTH_DIR, { recursive: true });
  }
  await newContext.storageState({ path: stateFile });
  validatedRoles.add(role);

  return page;
}

export const test = base.extend<AuthFixtures>({
  adminPage: async ({ context }, use) => {
    const page = await getAuthenticatedPage(context, 'admin');
    await use(page);
    await page.context().close();
  },

  memberPage: async ({ context }, use) => {
    const page = await getAuthenticatedPage(context, 'member');
    await use(page);
    await page.context().close();
  },

  emailTestPage: async ({ context }, use) => {
    const page = await getAuthenticatedPage(context, 'emailTest');
    await use(page);
    await page.context().close();
  },
});

export { expect } from '@playwright/test';
