import { defineConfig, devices } from '@playwright/test';

/**
 * Hermetic Keycloak theme tests.
 *
 * Unlike the main suite (../playwright.config.ts), these need no dev cluster,
 * tenant lease or test users: ci/scripts/keycloak-theme-test.sh boots the
 * Keycloak image pinned in apps/values/keycloak-codecentric.yaml with
 * apps/themes/platform mounted and points KC_THEME_TEST_URL at it. Run through
 * that script, not directly.
 */
export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  forbidOnly: !!process.env.CI,
  // Deterministic by construction (local container, virtual authenticator):
  // a retry would only hide a real theme break.
  retries: 0,
  workers: 1,
  reporter: [['list']],
  outputDir: '../test-results/keycloak-theme',
  timeout: 120_000,

  use: {
    ...devices['Desktop Chrome'],
    headless: true,
    screenshot: 'only-on-failure',
    // Tracing this spec (CDP virtual authenticator + standalone request
    // contexts) stalls worker teardown until the test timeout on a failure;
    // the assertion messages carry the page errors and failed URLs instead.
    trace: 'off',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
});
