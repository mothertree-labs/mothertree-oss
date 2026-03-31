import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { e2ePrefix } from '../../helpers/e2e-prefix';

/**
 * E2E tests for the Account Portal guest-landing route — redirect behavior.
 *
 * Verifies that:
 * - /guest-landing without params redirects to /register
 * - /guest-landing with a non-existent email redirects to /register
 */
test.describe('Smoke — Guest Landing Redirect Behavior', () => {
  test.setTimeout(90_000);

  test('redirects to /register when parameters are missing', async ({
    context,
  }) => {
    // Use an unauthenticated context
    const unauthContext = await context.browser()!.newContext({
      ignoreHTTPSErrors: true,
    });
    const page = await unauthContext.newPage();

    try {
      await page.goto(`${urls.accountPortal}/guest-landing`);
      await page.waitForLoadState('load');

      // Should redirect to /register
      expect(page.url()).toContain('/register');
    } finally {
      await unauthContext.close();
    }
  });

  test('redirects to /register for non-existent user email', async ({
    context,
  }) => {
    const unauthContext = await context.browser()!.newContext({
      ignoreHTTPSErrors: true,
    });
    const page = await unauthContext.newPage();
    const fakeEmail = `${e2ePrefix('fake')}-${Date.now()}@external-test.example`;

    try {
      await page.goto(
        `${urls.accountPortal}/guest-landing?email=${encodeURIComponent(fakeEmail)}&share=faketoken`,
      );
      await page.waitForLoadState('load');

      // Should redirect to /register with the email preserved
      expect(page.url()).toContain('/register');
      expect(page.url()).toContain(encodeURIComponent(fakeEmail));
    } finally {
      await unauthContext.close();
    }
  });
});
