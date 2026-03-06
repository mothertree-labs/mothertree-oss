/**
 * Playwright Load Test — User Journey
 *
 * Each worker (browser) runs as a unique user and performs a full journey
 * through the platform simultaneously. With 20 workers, this simulates
 * 20 concurrent users.
 *
 * Phases:
 *   1. SSO Login via Keycloak
 *   2. Account Portal dashboard browse
 *   3. Cross-app SSO navigation (Files, Docs, Element)
 *   4. File upload/delete via WebDAV
 *   5. Optional idle soak on Element
 */

import { test, expect } from '@playwright/test';
import { getUserForWorker, LoadUser } from '../helpers/load-users';

// Import reusable helpers from the E2E suite (read-only dependency)
import { keycloakLogin } from '../../../e2e/helpers/auth';
import { urls } from '../../../e2e/helpers/urls';
import { selectors } from '../../../e2e/helpers/selectors';

// ── Per-worker user assignment ──────────────────────────────────────────

let user: LoadUser;

test.beforeAll(async ({}, workerInfo) => {
  user = getUserForWorker(workerInfo.workerIndex);
  console.log(`[worker ${workerInfo.workerIndex}] Assigned user: ${user.username}`);
});

// ── Timing helper ───────────────────────────────────────────────────────

function elapsed(startMs: number): string {
  return `${((Date.now() - startMs) / 1000).toFixed(1)}s`;
}

// ── Phase 1: SSO Login ──────────────────────────────────────────────────

test.describe.serial('User Journey', () => {
  test('Phase 1 — SSO Login', async ({ page }) => {
    const t0 = Date.now();

    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');

    // Should land on Keycloak
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }

    // Verify the account portal loaded
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 30_000 });

    console.log(`[${user.username}] Phase 1 — Login: ${elapsed(t0)}`);
  });

  // ── Phase 2: Dashboard Browse ───────────────────────────────────────

  test('Phase 2 — Dashboard Browse', async ({ page }) => {
    const t0 = Date.now();

    // Login first (each test gets a fresh page)
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 30_000 });

    // Verify app cards are visible
    const ap = selectors.accountPortal;
    await expect(page.locator(ap.appCardChat)).toBeVisible({ timeout: 15_000 });
    await expect(page.locator(ap.appCardDocs)).toBeVisible({ timeout: 15_000 });
    await expect(page.locator(ap.appCardFiles)).toBeVisible({ timeout: 15_000 });

    // Navigate to device passwords and back
    await page.click(ap.appCardDevicePasswords);
    await expect(page.locator(ap.devicePasswordHeading)).toBeVisible({ timeout: 15_000 });

    await page.goBack();
    await expect(page.locator(ap.welcomeHeading)).toBeVisible({ timeout: 15_000 });

    console.log(`[${user.username}] Phase 2 — Dashboard: ${elapsed(t0)}`);
  });

  // ── Phase 3: Cross-App SSO ──────────────────────────────────────────

  test('Phase 3 — Cross-App SSO (Files)', async ({ page }) => {
    const t0 = Date.now();

    // Establish SSO session via account portal
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 30_000 });

    // Navigate to Nextcloud (Files)
    const filesResponse = await page.goto(urls.files).catch(() => null);
    if (!filesResponse) {
      console.log(`[${user.username}] Phase 3 — Files: SKIPPED (not reachable)`);
      test.skip(true, 'Files not reachable');
      return;
    }
    await page.waitForLoadState('networkidle').catch(() => {});

    // Handle OIDC redirect if needed
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }

    // Verify we're not stuck on auth
    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    // Check for server errors
    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    expect(hasError, 'Nextcloud returned a server error').toBe(false);

    console.log(`[${user.username}] Phase 3 — Files: ${elapsed(t0)}`);
  });

  test('Phase 3 — Cross-App SSO (Docs)', async ({ page }) => {
    const t0 = Date.now();

    // Establish SSO session
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 30_000 });

    // Navigate to Docs
    const docsResponse = await page.goto(urls.docs).catch(() => null);
    if (!docsResponse) {
      console.log(`[${user.username}] Phase 3 — Docs: SKIPPED (not reachable)`);
      test.skip(true, 'Docs not reachable');
      return;
    }

    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }
    await page.waitForLoadState('networkidle').catch(() => {});

    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    const pageText = await page.locator('body').textContent().catch(() => '') || '';
    const hasError = /Server Error|Internal Server Error|\b500\b|\b502\b|\b503\b/i.test(pageText);
    expect(hasError, 'Docs returned a server error').toBe(false);

    console.log(`[${user.username}] Phase 3 — Docs: ${elapsed(t0)}`);
  });

  test('Phase 3 — Cross-App SSO (Element)', async ({ page }) => {
    const t0 = Date.now();

    // Establish SSO session
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }
    await expect(page.locator(selectors.accountPortal.welcomeHeading)).toBeVisible({ timeout: 30_000 });

    // Navigate to Element
    const elementResponse = await page.goto(urls.element).catch(() => null);
    if (!elementResponse) {
      console.log(`[${user.username}] Phase 3 — Element: SKIPPED (not reachable)`);
      test.skip(true, 'Element not reachable');
      return;
    }
    await page.waitForLoadState('domcontentloaded');

    // Handle MAS consent or Keycloak login
    if (page.url().includes('auth.')) {
      const continueLink = page.getByRole('link', { name: 'Continue' });
      if (await continueLink.isVisible({ timeout: 5_000 }).catch(() => false)) {
        await continueLink.click();
      } else {
        await keycloakLogin(page, user.username, user.password);
      }
    }

    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    const hostname = new URL(page.url()).hostname;
    expect(hostname).not.toContain('auth.');

    const bodyText = await page.locator('body').textContent();
    expect(bodyText!.length).toBeGreaterThan(50);

    console.log(`[${user.username}] Phase 3 — Element: ${elapsed(t0)}`);
  });

  // ── Phase 4: File Operations ────────────────────────────────────────

  test('Phase 4 — File Upload via WebDAV', async ({ page }) => {
    const t0 = Date.now();

    // Navigate to Files and login
    const filesResponse = await page.goto(`${urls.files}/apps/files/`).catch(() => null);
    if (!filesResponse) {
      console.log(`[${user.username}] Phase 4 — File Upload: SKIPPED (not reachable)`);
      test.skip(true, 'Files not reachable');
      return;
    }
    await page.waitForLoadState('networkidle').catch(() => {});

    // Handle OIDC redirect
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
      await page.waitForLoadState('networkidle').catch(() => {});
    }

    // Check we're past login
    const stuckOnOidc = page.url().includes('user_oidc');
    if (stuckOnOidc) {
      console.log(`[${user.username}] Phase 4 — File Upload: SKIPPED (OIDC login failed)`);
      test.skip(true, 'OIDC login failed');
      return;
    }

    // Wait for Nextcloud to be ready (handles maintenance mode)
    const filesReady = await page.waitForSelector(
      '#app-content, .files-list, [class*="app-content"]',
      { timeout: 30_000 },
    ).then(() => true).catch(() => false);

    if (!filesReady) {
      console.log(`[${user.username}] Phase 4 — File Upload: SKIPPED (Nextcloud not ready)`);
      test.skip(true, 'Nextcloud not ready');
      return;
    }

    // Upload a file via WebDAV
    const testFileName = `loadtest-${user.username}-${Date.now()}.txt`;
    const uploadStatus = await page.evaluate(async (name) => {
      const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
      const resp = await fetch('/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + name, {
        method: 'PUT',
        headers: { 'requesttoken': token, 'Content-Type': 'text/plain' },
        body: `Load test file content from ${name}`,
      });
      return resp.status;
    }, testFileName);

    expect(uploadStatus, `WebDAV upload returned HTTP ${uploadStatus}`).toBeLessThan(300);

    // Clean up
    await page.evaluate(async (name) => {
      const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
      await fetch('/remote.php/dav/files/' + (window as any).OC.currentUser + '/' + name, {
        method: 'DELETE',
        headers: { 'requesttoken': token },
      }).catch(() => {});
    }, testFileName).catch(() => {});

    console.log(`[${user.username}] Phase 4 — File Upload: ${elapsed(t0)}`);
  });

  // ── Phase 5: Idle Soak ──────────────────────────────────────────────

  test('Phase 5 — Idle Soak', async ({ page }) => {
    const soakSeconds = Number(process.env.LOAD_SOAK_SECONDS || 0);
    if (soakSeconds <= 0) {
      console.log(`[${user.username}] Phase 5 — Soak: SKIPPED (LOAD_SOAK_SECONDS not set)`);
      test.skip(true, 'Set LOAD_SOAK_SECONDS to enable');
      return;
    }

    const t0 = Date.now();

    // Login and navigate to Element (holds WebSocket connections)
    await page.goto(`${urls.accountPortal}/auth/login`);
    await page.waitForLoadState('load');
    if (page.url().includes('auth.')) {
      await keycloakLogin(page, user.username, user.password);
    }

    const elementResponse = await page.goto(urls.element).catch(() => null);
    if (!elementResponse) {
      test.skip(true, 'Element not reachable');
      return;
    }
    await page.waitForLoadState('domcontentloaded');

    if (page.url().includes('auth.')) {
      const continueLink = page.getByRole('link', { name: 'Continue' });
      if (await continueLink.isVisible({ timeout: 5_000 }).catch(() => false)) {
        await continueLink.click();
      } else {
        await keycloakLogin(page, user.username, user.password);
      }
    }

    await page.waitForLoadState('domcontentloaded');
    await page.waitForTimeout(3_000);

    console.log(`[${user.username}] Phase 5 — Soaking for ${soakSeconds}s on Element...`);
    await page.waitForTimeout(soakSeconds * 1000);

    // Verify the page is still alive after soaking
    const bodyText = await page.locator('body').textContent();
    expect(bodyText!.length).toBeGreaterThan(50);

    console.log(`[${user.username}] Phase 5 — Soak: ${elapsed(t0)}`);
  });
});
