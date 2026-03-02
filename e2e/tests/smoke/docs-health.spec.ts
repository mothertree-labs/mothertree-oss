import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';

test.describe('Smoke — Docs Backend Health', () => {
  test('backend config endpoint returns 200', async ({ request }) => {
    // /api/v1.0/config/ is served by the Django backend directly.
    // When the backend is down (crash loop, CPU throttling, gunicorn timeout),
    // the frontend may still serve static assets but API calls return 502/503.
    // This catches backend-specific outages that the frontend UI masks.
    const response = await request.get(`${urls.docs}/api/v1.0/config/`);
    const status = response.status();

    if (status === 0) {
      test.skip(true, 'Docs not reachable (DNS or connection error)');
    }

    expect(
      status,
      `Docs backend returned HTTP ${status}. ` +
      (status === 502 || status === 503
        ? 'Backend is likely down (crash loop or CPU throttled). ' +
          'Check: kubectl get pods -n tn-<tenant>-docs -l io.kompose.service=backend'
        : `Expected 200, got ${status}`)
    ).toBe(200);
  });

  test('backend config endpoint returns valid JSON', async ({ request }) => {
    // When nginx can't reach the backend, it may return an HTML error page
    // with a 502 status. But even with 200, we should verify the response
    // is actual JSON from Django, not an nginx error page.
    const response = await request.get(`${urls.docs}/api/v1.0/config/`);

    if (!response.ok()) {
      test.skip(true, `Docs backend not OK (HTTP ${response.status()})`);
    }

    const contentType = response.headers()['content-type'] || '';
    expect(
      contentType,
      'Expected JSON content-type from Django backend, got: ' + contentType +
      '. This may indicate nginx is serving an error page instead of proxying to the backend.'
    ).toContain('application/json');

    const body = await response.json();
    expect(body).toBeDefined();
  });
});
