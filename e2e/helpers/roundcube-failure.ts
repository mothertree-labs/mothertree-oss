import type { Page } from '@playwright/test';

/**
 * Capture, at the moment a Roundcube OIDC login fails to reach the inbox,
 * WHERE the browser got stuck.
 *
 * The Playwright timeout alone ("ROUNDCUBE_INBOX never appeared") cannot tell
 * the failure layers apart. This logs the final URL/host + visible page text so
 * the CI log shows whether the browser was:
 *   - stuck on Keycloak  -> redirect/login never completed (KC client/redirect/session)
 *   - on the webmail host with no inbox -> OIDC returned but the app never
 *     rendered the inbox (Roundcube app/session, or Stalwart OAUTHBEARER)
 *   - on an error page   -> the visible text usually names the error
 *
 * Pairs with the server-side pod-log dump in ci/scripts/ci-e2e-diagnostics.sh.
 * Best-effort: NEVER throws, so it cannot mask the real assertion failure.
 */
export async function captureRoundcubeStuckState(page: Page, label: string): Promise<void> {
  try {
    const url = page.url();
    let host = '(unparseable)';
    // Log only origin+pathname — a STUCK OIDC URL can carry an auth `code`/`state`
    // (or tokens in hybrid flows) in its query/fragment. The path (e.g.
    // /realms/<realm>/protocol/openid-connect/auth) is the diagnostic signal we
    // want; the query/fragment is not, and must not land in the CI log.
    let safeUrl = url.split('?')[0].split('#')[0];
    try {
      const u = new URL(url);
      host = u.host;
      safeUrl = `${u.origin}${u.pathname}`;
    } catch {
      /* keep defaults */
    }
    const onKeycloak =
      /(^|\.)auth\./.test(host) ||
      url.includes('/realms/') ||
      url.includes('/protocol/openid-connect');
    const title = await page.title().catch(() => '(no title)');
    const bodyText = (
      await page.locator('body').innerText({ timeout: 2_000 }).catch(() => '')
    )
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 600);

    const verdict = onKeycloak
      ? 'STUCK ON KEYCLOAK — OIDC redirect/login did not complete (suspect KC client/redirect or session)'
      : 'ON WEBMAIL HOST, NO INBOX — OIDC returned but inbox never rendered (suspect Roundcube app/session or Stalwart OAUTHBEARER)';

    console.log(`\n  [roundcube-stuck:${label}] ${verdict}`);
    console.log(`  [roundcube-stuck:${label}] final URL : ${safeUrl}`);
    console.log(`  [roundcube-stuck:${label}] host      : ${host}`);
    console.log(`  [roundcube-stuck:${label}] title     : ${title}`);
    console.log(`  [roundcube-stuck:${label}] body text : ${bodyText || '(empty)'}`);
  } catch (e) {
    console.log(`  [roundcube-stuck:${label}] capture failed: ${(e as Error)?.message ?? e}`);
  }
}
