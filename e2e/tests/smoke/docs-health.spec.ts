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

  test('email logo asset is served by the frontend', async ({ request }) => {
    // Invitation/share emails reference DJANGO_EMAIL_LOGO_IMG, which points at
    // /email-assets/logo-email.png served from the docs-email-assets ConfigMap
    // mounted into the frontend nginx. If the mount or ConfigMap is missing,
    // every share email renders a broken logo image.
    const response = await request.get(`${urls.docs}/email-assets/logo-email.png`);

    if (response.status() === 0) {
      test.skip(true, 'Docs not reachable (DNS or connection error)');
    }

    expect(
      response.status(),
      'Expected the email logo at /email-assets/logo-email.png to be served. ' +
      'Check the docs-email-assets ConfigMap and its volume mount in the frontend deployment.'
    ).toBe(200);

    const contentType = response.headers()['content-type'] || '';
    expect(
      contentType,
      'Expected an image content-type for the email logo, got: ' + contentType
    ).toContain('image/png');
  });

  test('collaboration server publishes its JWKS', async ({ request }) => {
    // impress >= 6: the collaboration server (yhub) publishes the public half
    // of the key it signs its calls to the backend with; the backend reads it
    // in-cluster, and it is one of the routes the docs-yhub ingress publishes.
    // A 404/HTML here means /collaboration/ is not routed to yhub.
    const response = await request.get(`${urls.docs}/collaboration/jwks/v1`);

    if (response.status() === 0) {
      test.skip(true, 'Docs not reachable (DNS or connection error)');
    }

    expect(
      response.status(),
      'Expected /collaboration/jwks/v1 to be served by yhub. ' +
      'Check the docs-yhub ingress and the docs-yhub deployment.'
    ).toBe(200);
    const body = await response.json();
    expect(Array.isArray(body.keys) && body.keys.length > 0, 'JWKS has no keys').toBe(true);
    for (const key of body.keys) {
      // Public half only: an RSA private JWK carries "d".
      expect(key.d, 'JWKS must not carry private key material').toBeUndefined();
    }
  });

  test('collaboration server keeps its backend-only routes in-cluster', async ({ request }) => {
    // migrate / reset-ydoc / create-ydoc / restore-ydoc / reset-connections /
    // prune are admin-JWT routes for the backend. The ingress publishes only
    // the browser routes, so from outside these must never reach yhub (which
    // answers JSON); they fall through to the frontend instead.
    const id = '00000000-0000-4000-8000-000000000000';
    for (const route of ['migrate', 'reset-ydoc', 'create-ydoc', 'restore-ydoc', 'reset-connections', 'prune']) {
      const response = await request.post(`${urls.docs}/collaboration/${route}/v1/docs/${id}`, {
        maxRedirects: 0,
      });
      if (response.status() === 0) {
        test.skip(true, 'Docs not reachable (DNS or connection error)');
      }
      const contentType = response.headers()['content-type'] || '';
      expect(
        contentType.includes('application/json'),
        `/collaboration/${route}/ answered JSON (HTTP ${response.status()}): it is published to yhub`,
      ).toBe(false);
    }

    // The ingress matches on the normalised path but proxies the raw URI, so
    // an encoded traversal or backslash under a published prefix must not be
    // handed to yhub's router (configuration-snippet in yhub-ingress.yaml.tpl).
    for (const raw of [
      `/collaboration/ws/..%5Cmigrate/v1/docs/${id}`,
      // (a bare %2e%2e segment is not listed: the WHATWG URL parser of the
      // client itself resolves it to /collaboration/migrate/ before sending)
      `/collaboration/ws/x%2e%2e%5Cmigrate/v1/docs/${id}`,
      `/collaboration/ydoc/%2e%2e%2Freset-ydoc/v1/docs/${id}`,
    ]) {
      // Depending on how nginx normalises it, the URI lands either in a
      // published yhub location (refused there with 404) or on the frontend;
      // either way it must never be answered by yhub, which speaks JSON.
      const response = await request.post(`${urls.docs}${raw}`, { maxRedirects: 0 });
      const contentType = response.headers()['content-type'] || '';
      expect(
        contentType.includes('application/json'),
        `${raw} reached yhub (HTTP ${response.status()}, ${contentType})`,
      ).toBe(false);
    }
  });
});
