import { test, expect } from '@playwright/test';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';

/**
 * Session-longevity regression guard.
 *
 * Nextcloud — and any app that uses an ONLINE OIDC session (scope without
 * `offline_access`) — is bound to the realm's SSO session timeouts. Those have
 * silently regressed to short values more than once, bouncing users to the login
 * screen roughly once a day. The realm now sets long base sessions
 * (docs/keycloak-realm-config.json.tpl: ssoSessionIdleTimeout / ssoSessionMaxLifespan).
 *
 * This checks it behaviourally and cheaply — no browser, no waiting out the
 * 5-minute access-token boundary. `admin-cli` is a public direct-access-grant
 * client, so a password grant with scope `openid` (deliberately NO
 * `offline_access`) returns a refresh token whose `refresh_expires_in` equals the
 * realm's ssoSessionIdleTimeout. If that ever collapses back toward ~7200s (the
 * old 2h cap), this test fails before the config can ship.
 *
 * Complements the deploy-time drift gate in docs/import-keycloak-realm.sh, which
 * guards the same values on every deploy (including prod, where e2e does not run).
 */
const realm = process.env.E2E_KC_REALM || 'docs';
const tokenEndpoint = `${urls.keycloak}/realms/${realm}/protocol/openid-connect/token`;

// The realm intends 30-day sessions; require at least 7 days so the assertion is
// robust to a deliberate future trim while still catching the 2h/10h regression.
const MIN_ONLINE_REFRESH_SECONDS = 7 * 24 * 60 * 60; // 604800

test.describe('SSO — session longevity (regression guard)', () => {
  test('online OIDC refresh token outlives a work session (no premature logout)', async ({ request }) => {
    const res = await request.post(tokenEndpoint, {
      form: {
        grant_type: 'password',
        client_id: 'admin-cli',
        username: TEST_USERS.admin.username,
        password: TEST_USERS.admin.password,
        scope: 'openid', // NO offline_access → refresh_expires_in reflects ssoSessionIdleTimeout
      },
    });
    expect(
      res.ok(),
      `token request failed: HTTP ${res.status()} — ${await res.text()}`,
    ).toBeTruthy();

    const body = await res.json();
    const refreshExpiresIn = body.refresh_expires_in;
    expect(
      refreshExpiresIn,
      `refresh_expires_in=${refreshExpiresIn}s is below the ${MIN_ONLINE_REFRESH_SECONDS}s floor — ` +
        'the realm SSO session timeouts have regressed to short values (the Nextcloud ~daily-logout bug). ' +
        'Check ssoSessionIdleTimeout / ssoSessionMaxLifespan in docs/keycloak-realm-config.json.tpl.',
    ).toBeGreaterThanOrEqual(MIN_ONLINE_REFRESH_SECONDS);
  });
});
