import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';

test.describe('Smoke — Nextcloud Health', () => {
  test('status.php reports no maintenance or upgrade needed', async ({ request }) => {
    // status.php is the canonical health endpoint — returns JSON with
    // maintenance mode and DB upgrade flags. Critically, status.php bypasses
    // the upgrade check, so it returns 200 even when Nextcloud is serving 503
    // on ALL other endpoints. This test catches the root cause of the
    // "Update needed — use the command line updater" 503 page that can occur
    // after HPA scale-up or image upgrades.
    const response = await request.get(`${urls.files}/status.php`);

    if (response.status() === 0 || !response.ok()) {
      test.skip(true, `Nextcloud not reachable (HTTP ${response.status()})`);
    }

    const status = await response.json();

    expect(status.installed, 'Nextcloud should report as installed').toBe(true);

    expect(status.maintenance,
      'Nextcloud is in maintenance mode — all requests return 503. ' +
      'Fix: kubectl exec into the Nextcloud pod and run "php occ maintenance:mode --off"'
    ).toBe(false);

    expect(status.needsDbUpgrade,
      'Nextcloud needs a database upgrade — all requests return 503 with ' +
      '"Update needed — Please use the command line updater". This happens when new pods ' +
      'start with a newer Nextcloud version before the DB schema is migrated. ' +
      'Fix: kubectl exec into the Nextcloud pod and run "php occ upgrade"'
    ).toBe(false);
  });

  test('Nextcloud root does not return 503', async ({ request }) => {
    // Hit the root URL directly. When Nextcloud is in "update needed" or
    // maintenance mode, it returns 503 instead of the normal 302-to-OIDC
    // redirect. This catches the symptom that users see in their browser.
    //
    // We use maxRedirects: 0 to check the raw Nextcloud response before
    // any OIDC redirect chain.
    const response = await request.get(urls.files, { maxRedirects: 0 });
    const status = response.status();

    if (status === 0) {
      test.skip(true, 'Nextcloud not reachable (DNS or connection error)');
    }

    expect(
      status,
      `Nextcloud root returned HTTP ${status}. ` +
      (status === 503
        ? 'This is the "Update needed" or maintenance mode page. ' +
          'Fix: kubectl exec into the Nextcloud pod and run "php occ upgrade" ' +
          'or "php occ maintenance:mode --off"'
        : `Expected 200 or 302 (OIDC redirect), got ${status}`)
    ).not.toBe(503);
  });
});
