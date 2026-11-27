import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';

/**
 * Docs (impress >= 6): the content of a document lives in the collaboration
 * server (yhub), reached over the editor websocket. This is the one spec that
 * actually edits a document, so it is what proves the whole chain:
 *
 *   browser ──wss /collaboration/ws/v1/docs/<id>──▶ yhub (auth via backend
 *   /users/me + /documents/<id>/abilities, Redis stream, PostgreSQL)
 *   backend ──YHUB_API_BASE_URL──▶ yhub (admin JWT) ──▶ y-provider (convert)
 *
 * The text typed in the editor must come back (1) from the backend's
 * formatted-content endpoint, which reads the document from yhub server-side
 * and converts it through the y-provider, and (2) in the editor after a
 * reload, i.e. from yhub rather than the browser's own state.
 */
test.describe('Docs — collaborative editing', () => {
  test.setTimeout(180_000);

  test('typed content is saved by the collaboration server and survives a reload', async ({
    memberPage: page,
  }) => {
    const user = TEST_USERS.member;
    const marker = `e2e-yhub-${Date.now()}`;
    let docId = '';
    let apiHeaders: Record<string, string> = {};

    try {
      // ── Login to Docs (client-side OIDC redirect, as in the invitation spec)
      await page.goto(urls.docs);
      await page
        .waitForURL((u) => u.hostname.startsWith('auth.'), { timeout: 20_000 })
        .catch(() => {}); // already authenticated → no redirect
      if (new URL(page.url()).hostname.startsWith('auth.')) {
        await keycloakLogin(page, user.username, user.password);
        await page.waitForURL((u) => !u.hostname.startsWith('auth.'), { timeout: 30_000 });
      }
      await expect
        .poll(async () => (await page.request.get(`${urls.docs}/api/v1.0/users/me/`)).status(), {
          message: 'Docs API never returned 200 for /users/me/ — OIDC login did not complete',
          timeout: 60_000,
        })
        .toBe(200);

      const cookies = await page.context().cookies(urls.docs);
      const csrfToken = cookies.find((c) => c.name === 'csrftoken')?.value;
      expect(csrfToken, 'Expected a csrftoken cookie after logging into Docs').toBeTruthy();
      apiHeaders = { 'X-CSRFToken': csrfToken!, Referer: `${urls.docs}/`, Origin: urls.docs };

      // impress 6 shows a first-connection onboarding modal over the editor
      // ("Compose your doc easily") that swallows clicks; mark it seen, as
      // the frontend does when it is dismissed.
      const onboardingResp = await page.request.post(`${urls.docs}/api/v1.0/users/onboarding-done/`, {
        headers: apiHeaders,
      });
      expect(onboardingResp.status(), 'POST users/onboarding-done/ failed').toBe(200);

      // ── Create a document (backend → yhub create-ydoc in-cluster)
      const createResp = await page.request.post(`${urls.docs}/api/v1.0/documents/`, {
        headers: apiHeaders,
        data: { title: `E2E collaboration ${marker}` },
      });
      expect(
        createResp.status(),
        `Document creation failed: HTTP ${createResp.status()} — ${await createResp.text().catch(() => '')}`,
      ).toBe(201);
      docId = (await createResp.json()).id;

      // ── Open it and type into the editor (websocket to yhub)
      await page.goto(`${urls.docs}/docs/${docId}/`);
      const editor = page.locator('.ProseMirror[contenteditable="true"]').first();
      await expect(editor, 'The editor never became editable (websocket to yhub?)').toBeVisible({
        timeout: 60_000,
      });
      await editor.click();
      await page.keyboard.type(marker, { delay: 20 });
      await expect(editor).toContainText(marker);

      // ── (1) Server-side read: backend → yhub → y-provider conversion
      await expect
        .poll(
          async () => {
            const r = await page.request.get(
              `${urls.docs}/api/v1.0/documents/${docId}/formatted-content/?content_format=markdown`,
            );
            if (!r.ok()) return `HTTP ${r.status()}`;
            return JSON.stringify(await r.json());
          },
          {
            message: 'formatted-content never returned the typed text (yhub persistence or y-provider conversion)',
            timeout: 60_000,
            intervals: [2_000, 3_000, 5_000],
          },
        )
        .toContain(marker);

      // ── (2) Reload: the content must come back from yhub
      await page.reload();
      const reloaded = page.locator('.ProseMirror[contenteditable="true"]').first();
      await expect(reloaded).toBeVisible({ timeout: 60_000 });
      await expect(reloaded, 'Typed text was gone after a reload').toContainText(marker, {
        timeout: 30_000,
      });
    } finally {
      if (docId) {
        await page.request
          .delete(`${urls.docs}/api/v1.0/documents/${docId}/`, { headers: apiHeaders })
          .catch(() => {});
      }
    }
  });
});
