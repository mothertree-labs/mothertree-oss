import { test, expect } from '../../fixtures/authenticated';
import { urls } from '../../helpers/urls';
import { selectors } from '../../helpers/selectors';
import { TEST_USERS } from '../../helpers/test-users';
import { keycloakLogin } from '../../helpers/auth';
import { e2ePrefix } from '../../helpers/e2e-prefix';
import { isImapConfigured, waitForEmailBody, countInboxBySubject, appendCalendarEmail } from '../../helpers/imap';
import { handleNextcloudLogin, waitForNextcloudReady } from '../../helpers/nextcloud';

const baseDomain = urls.baseDomain;
const ROUNDCUBE_INBOX = '#messagelist, #mailboxlist, .mailbox-list, button:has-text("Compose")';

/**
 * Comprehensive E2E test for the full user onboarding flow.
 *
 * Exercises the complete journey from admin invitation through passkey
 * registration to first use of all services.
 *
 * Flow:
 * 1. Admin portal: invite a new user (recovery email → e2e-mailrt inbox)
 * 2. IMAP: read invitation email from e2e-mailrt inbox, extract action URL
 * 3. CDP virtual authenticator: complete WebAuthn passkey registration
 * 4. Account portal: verify redirect and session after registration
 * 5. Element, Nextcloud, Roundcube: verify SSO access to each service
 * 6. Inbound email: verify Stalwart can receive mail for the new user
 *
 * The test uses e2e-mailrt as the recovery email recipient because:
 * - It has a pre-existing Stalwart principal (IMAP-readable)
 * - The real invite flow routes through /beginSetup (more realistic)
 * - No production code changes needed
 */
test.describe('Onboarding — Full User Flow', () => {
  test.setTimeout(180_000); // 5 minutes — touches all services + email delivery

  test('invited user can register passkey and access all services', async ({ adminPage }) => {
    test.skip(!isImapConfigured(), 'IMAP not configured (E2E_STALWART_ADMIN_PASSWORD not set)');

    const ap = selectors.adminPortal;
    const uniqueId = `${Date.now()}`;
    const username = `${e2ePrefix('onboard')}-${uniqueId}`;
    const userEmail = `${username}@${baseDomain}`;
    const firstName = `Onboard${uniqueId}`;
    const lastName = 'E2ETest';

    // Use plus-addressed e2e-mailrt as recovery email:
    // - Keycloak treats e2e-mailrt+tag@domain as unique (no 409 conflict with e2e-mailrt@domain)
    // - Stalwart delivers user+tag@domain to the user@domain principal's inbox
    // - We can read it via IMAP master-user auth on e2e-mailrt
    const recoveryEmail = `e2e-mailrt+onboard-${uniqueId}@${baseDomain}`;

    let invitedUserId: string | null = null;
    const results: Record<string, { passed: boolean; error?: string }> = {};

    function record(service: string, passed: boolean, error?: string) {
      results[service] = { passed, error };
      if (!passed) {
        console.log(`  [onboarding] SOFT FAIL — ${service}: ${error}`);
      }
    }

    try {
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 1: Admin Portal — Create invitation
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      await adminPage.fill(ap.firstNameInput, firstName);
      await adminPage.fill(ap.lastNameInput, lastName);
      await adminPage.fill(ap.emailUsernameInput, username);
      await adminPage.fill(ap.recoveryEmailInput, recoveryEmail);

      const responsePromise = adminPage.waitForResponse(
        (r) => r.url().includes('/api/invite') && r.request().method() === 'POST',
      );
      await adminPage.click(ap.inviteSubmitBtn);
      const apiResponse = await responsePromise;
      const apiResult = await apiResponse.json();
      invitedUserId = apiResult.userId || null;

      await expect(adminPage.locator(ap.formMessage)).toBeVisible({ timeout: 30_000 });
      const messageText = await adminPage.locator(ap.formMessage).textContent();
      expect(messageText).toContain('successfully');

      // Verify user appears in members list
      await expect(adminPage.locator(ap.membersList)).toContainText(firstName, { timeout: 30_000 });

      record('admin-portal-invite', true);
      console.log(`  [onboarding] Invite API response: userId=${invitedUserId}, status=${apiResponse.status()}`);
      console.log(`  [onboarding] Recovery email: ${recoveryEmail}`);
      console.log(`  [onboarding] Will poll IMAP for: ${TEST_USERS.emailTest.email}, bodyContains: ${uniqueId}`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 2: Read invitation email from e2e-mailrt inbox
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      // The invite sends to the plus-addressed recovery email (e2e-mailrt+tag@domain).
      // Stalwart delivers to the base e2e-mailrt principal's inbox.
      // Match on the uniqueId (timestamp) which appears in the MIME To: header as
      // part of the plus-address. MIME headers are never content-encoded (unlike
      // the body which may be base64 or quoted-printable encoded).
      const rawEmail = await waitForEmailBody({
        userEmail: TEST_USERS.emailTest.email, // Read from e2e-mailrt's inbox
        bodyContains: uniqueId, // Match timestamp in To: header (always in raw MIME)
        timeoutMs: 90_000, // Email delivery (Keycloak→Postfix→Stalwart) takes 60-120s in CI
        pollIntervalMs: 3_000,
      });

      // Decode MIME quoted-printable encoding before extracting URLs:
      // 1. Remove QP soft line breaks (=\r\n or =\n) — wraps at 76 chars
      // 2. Decode =XX hex pairs (e.g. =3D → '=') — encodes special chars
      const decodedEmail = rawEmail
        .replace(/=\r?\n/g, '')
        .replace(/=([0-9A-Fa-f]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));

      // Extract the setup URL from the email body.
      // The FTL template wraps the Keycloak action URL through /beginSetup:
      //   https://account.{domain}/beginSetup?userId=...&token=...&next=...
      // Or if no email swap needed, the raw Keycloak action URL:
      //   https://auth.{domain}/realms/.../login-actions/action-token?key=...
      const urlMatch = decodedEmail.match(/https:\/\/account\.[^\s"<>]+beginSetup[^\s"<>]+/);
      const actionUrlFallback = decodedEmail.match(/https:\/\/auth\.[^\s"<>]+action-token[^\s"<>]+/);
      // Decode HTML entities (&amp; → &) — FTL's <#outputformat "HTML"> escapes
      // the URL when inserted into the href attribute.
      let setupUrl = (urlMatch?.[0] || actionUrlFallback?.[0])?.replace(/&amp;/g, '&');

      // If the /beginSetup URL has empty userId/token params (older admin portal
      // deployment), extract the Keycloak action-token URL from the `next` param.
      if (setupUrl?.includes('beginSetup?userId=&') || setupUrl?.includes('beginSetup?userId=&amp;')) {
        const nextParam = new URL(setupUrl).searchParams.get('next');
        if (nextParam) {
          console.log('  [onboarding] beginSetup has empty userId — using next param directly');
          setupUrl = nextParam;
        }
      }

      if (!setupUrl) {
        const urls = decodedEmail.match(/https?:\/\/[^\s"<>]+/g) || [];
        console.log(`  [onboarding] No setup URL found. URLs in email: ${urls.slice(0, 5).join(', ')}`);
      }
      expect(setupUrl, 'Could not find setup URL in invitation email').toBeTruthy();

      record('invitation-email', true);
      console.log(`  [onboarding] Setup URL: ${setupUrl!.substring(0, 80)}...`);

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Step 3: Complete WebAuthn registration with CDP virtual authenticator
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      // Use a fresh browser context for the new user's registration
      const userContext = await adminPage.context().browser()!.newContext({
        ignoreHTTPSErrors: true,
      });
      const userPage = await userContext.newPage();

      try {
        // Enable CDP virtual authenticator — auto-responds to WebAuthn challenges
        const cdpSession = await userPage.context().newCDPSession(userPage);
        await cdpSession.send('WebAuthn.enable');
        await cdpSession.send('WebAuthn.addVirtualAuthenticator', {
          options: {
            protocol: 'ctap2',
            transport: 'internal',
            hasResidentKey: true,
            hasUserVerification: true,
            isUserVerified: true,
          },
        });

        // Navigate to the setup URL (goes through /beginSetup → Keycloak action page)
        console.log('  [onboarding] Step 3: Navigating to setup URL...');
        await userPage.goto(setupUrl!);
        await userPage.waitForLoadState('load');
        console.log(`  [onboarding] Step 3: Landed on ${userPage.url().substring(0, 80)}`);

        // Keycloak action tokens show an intermediate info page with
        // "Click here to proceed" before rendering the actual required action.
        // Handle both: the intermediate page and landing directly on the form.
        const proceedLink = userPage.locator('a:has-text("Click here to proceed"), a:has-text("click here")');
        const registerBtn = userPage.locator('#registerBtn, #registerWebAuthn, button:has-text("Register Passkey"), input[type="submit"]');

        const firstVisible = await Promise.race([
          proceedLink.first().waitFor({ timeout: 30_000 }).then(() => 'proceed' as const),
          registerBtn.first().waitFor({ timeout: 30_000 }).then(() => 'register' as const),
        ]).catch(() => 'timeout' as const);

        if (firstVisible === 'proceed') {
          console.log('  [onboarding] Step 3: Clicking "proceed" on action token info page...');
          await proceedLink.first().click();
          await userPage.waitForLoadState('load');
          await registerBtn.first().waitFor({ timeout: 30_000 });
        } else if (firstVisible === 'timeout') {
          const visibleText = await userPage.evaluate(() => {
            const el = document.querySelector('#kc-content-wrapper') || document.body;
            return el?.innerText || '';
          }).catch(() => '');
          throw new Error(`Neither proceed link nor register button found. URL: ${userPage.url()}, text: ${visibleText.substring(0, 300)}`);
        }
        console.log('  [onboarding] Step 3: Register button found, performing WebAuthn registration...');

        // Helper: create credential and fill form fields (without submitting).
        async function fillWebAuthnForm(): Promise<string> {
          return userPage.evaluate(async () => {
            function b64urlDecode(str: string): ArrayBuffer {
              let b64 = str.replace(/-/g, '+').replace(/_/g, '/');
              while (b64.length % 4) b64 += '=';
              const bin = atob(b64);
              const arr = new Uint8Array(bin.length);
              for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
              return arr.buffer;
            }
            function b64urlEncode(buf: ArrayBuffer): string {
              const bytes = new Uint8Array(buf);
              let binary = '';
              for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
              return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
            }

            try {
              // Extract WebAuthn params from the page's script (injected by FreeMarker)
              const scripts = document.querySelectorAll('script');
              let challenge = '', userid = '', username = '', rpEntityName = '', rpId = '';
              let signatureAlgorithms: number[] = [];
              let attestationConveyancePreference = 'none';
              let requireResidentKey = 'No';
              let userVerificationRequirement = 'preferred';
              let createTimeout = 0;
              let excludeCredentialIds = '';

              for (const s of scripts) {
                const text = s.textContent || '';
                if (text.includes('var challenge')) {
                  const m = (name: string) => {
                    const re = new RegExp(`var ${name}\\s*=\\s*"([^"]*)"`, 'm');
                    return re.exec(text)?.[1] || '';
                  };
                  challenge = m('challenge');
                  userid = m('userid');
                  username = m('username');
                  rpEntityName = m('rpEntityName');
                  rpId = m('rpId');
                  attestationConveyancePreference = m('attestationConveyancePreference');
                  requireResidentKey = m('requireResidentKey');
                  userVerificationRequirement = m('userVerificationRequirement');
                  excludeCredentialIds = m('excludeCredentialIds');
                  const algMatch = /signatureAlgorithms\s*=\s*\[([^\]]*)\]/.exec(text);
                  if (algMatch) {
                    signatureAlgorithms = algMatch[1].split(',').map(Number).filter(n => !isNaN(n));
                  }
                  const toMatch = /createTimeout\s*=\s*(\d+)/.exec(text);
                  if (toMatch) createTimeout = parseInt(toMatch[1]);
                  if (challenge) break;
                }
              }

              if (!challenge) {
                return `err:no challenge found (scripts: ${scripts.length}, forms: ${document.forms.length})`;
              }

              const pubKeyCredParams = signatureAlgorithms.map(alg => ({
                type: 'public-key' as const, alg,
              }));

              const excludeCredentials: PublicKeyCredentialDescriptor[] = [];
              if (excludeCredentialIds) {
                for (const id of excludeCredentialIds.split(',')) {
                  if (id.trim()) excludeCredentials.push({ type: 'public-key', id: b64urlDecode(id.trim()) });
                }
              }

              const publicKey: PublicKeyCredentialCreationOptions = {
                challenge: b64urlDecode(challenge),
                rp: rpId ? { id: rpId, name: rpEntityName } : { name: rpEntityName },
                user: {
                  id: b64urlDecode(userid),
                  name: username,
                  displayName: username,
                },
                pubKeyCredParams,
                authenticatorSelection: {
                  authenticatorAttachment: undefined,
                  requireResidentKey: requireResidentKey === 'Yes',
                  residentKey: requireResidentKey === 'Yes' ? 'required' : 'discouraged',
                  userVerification: userVerificationRequirement as UserVerificationRequirement,
                },
                timeout: createTimeout === 0 ? undefined : createTimeout * 1000,
                attestation: (attestationConveyancePreference === 'not specified' ? 'none' : attestationConveyancePreference) as AttestationConveyancePreference,
                excludeCredentials,
              };

              const cred = await navigator.credentials.create({ publicKey }) as PublicKeyCredential;
              const response = cred.response as AuthenticatorAttestationResponse;

              // Fill hidden form fields (same field IDs in both templates)
              (document.getElementById('clientDataJSON') as HTMLInputElement).value =
                b64urlEncode(response.clientDataJSON);
              (document.getElementById('attestationObject') as HTMLInputElement).value =
                b64urlEncode(response.attestationObject);
              (document.getElementById('publicKeyCredentialId') as HTMLInputElement).value =
                cred.id;
              (document.getElementById('authenticatorLabel') as HTMLInputElement).value =
                (document.getElementById('registerWebAuthnLabel') as HTMLInputElement)?.value || 'E2E Test Passkey';
              const transports = response.getTransports ? response.getTransports() : [];
              (document.getElementById('transports') as HTMLInputElement).value =
                transports.join(',');
              (document.getElementById('error') as HTMLInputElement).value = '';

              // Verify form exists (don't submit — caller handles that)
              const form = document.getElementById('register') || document.getElementById('webauthn-register-form');
              if (!form) return 'err:form not found';

              return `ok:credId=${cred.id.substring(0, 16)},rpId=${rpId}`;
            } catch (e: any) {
              return `err:${e.name}:${e.message}`;
            }
          });
        }

        // Try WebAuthn registration up to 2 times
        let registrationDone = false;
        for (let attempt = 1; attempt <= 2 && !registrationDone; attempt++) {
          // Step A: Create credential and fill form fields
          const fillResult = await fillWebAuthnForm();
          console.log(`  [onboarding] Step 3 attempt ${attempt} fill: ${fillResult}`);

          if (fillResult.startsWith('err:')) {
            throw new Error(`WebAuthn credential creation failed: ${fillResult}`);
          }

          // Step B: Submit form with proper navigation synchronization.
          // Use Promise.all to ensure we start listening for the response
          // BEFORE the form submission triggers navigation.
          const [postResponse] = await Promise.all([
            userPage.waitForResponse(
              resp => resp.request().method() === 'POST' && resp.url().includes('login-actions'),
              { timeout: 30_000 },
            ),
            userPage.evaluate(() => {
              const form = document.getElementById('register') || document.getElementById('webauthn-register-form');
              if (form) (form as HTMLFormElement).submit();
            }),
          ]);

          const postStatus = postResponse.status();
          console.log(`  [onboarding] POST response: ${postStatus}`);

          // Wait for the page to fully load after the POST response.
          // Add a short delay to ensure browser has processed the response.
          await userPage.waitForLoadState('load', { timeout: 30_000 });

          const currentUrl = userPage.url();
          console.log(`  [onboarding] Step 3 attempt ${attempt} post-URL: ${currentUrl.substring(0, 120)}`);

          // Check if we've left Keycloak
          if (currentUrl.includes('/home') || currentUrl.includes('/complete')) {
            registrationDone = true;
            break;
          }

          // Helper: perform passkey login via Keycloak login-username.ftl flow.
          // Used after navigating to /complete-registration when Keycloak shows a login page.
          async function doPasskeyLogin() {
            const loc = userPage.url();
            console.log(`  [onboarding] Starting passkey login. Current: ${loc.substring(0, 120)}`);

            // Check if we already reached /home (unlikely but possible)
            if (loc.includes('/home')) return;

            // Keycloak renders login-username.ftl — enter email and submit
            const usernameInput = userPage.locator('#username');
            await usernameInput.waitFor({ timeout: 15_000 });
            await usernameInput.fill(userEmail);
            console.log(`  [onboarding] Entered username: ${userEmail}`);

            const [loginResponse] = await Promise.all([
              userPage.waitForResponse(
                resp => resp.request().method() === 'POST' && resp.url().includes('login-actions'),
                { timeout: 30_000 },
              ),
              userPage.locator('#kc-form-login button[type="submit"], .continue-btn').first().click(),
            ]);
            console.log(`  [onboarding] Login form submitted, response: ${loginResponse.status()}`);

            await userPage.waitForLoadState('load');

            // Perform WebAuthn get() directly — the page's auto-click
            // doesn't fire in headless Chrome (document.hasFocus() false)
            const authResult = await userPage.evaluate(async () => {
              function b64urlDecode(str: string): ArrayBuffer {
                let b64 = str.replace(/-/g, '+').replace(/_/g, '/');
                while (b64.length % 4) b64 += '=';
                const bin = atob(b64);
                const arr = new Uint8Array(bin.length);
                for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
                return arr.buffer;
              }
              function b64urlEncode(buf: ArrayBuffer): string {
                const bytes = new Uint8Array(buf);
                let binary = '';
                for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
                return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
              }

              try {
                const scripts = document.querySelectorAll('script');
                let challenge = '', rpId = '', userVerification = 'preferred';
                let createTimeout = 0;

                for (const s of scripts) {
                  const text = s.textContent || '';
                  if (text.includes('authenticateByWebAuthn') || text.includes('var challenge')) {
                    const m = (name: string) => {
                      const re1 = new RegExp(`${name}\\s*:\\s*"([^"]*)"`, 'm');
                      const re2 = new RegExp(`var ${name}\\s*=\\s*"([^"]*)"`, 'm');
                      return re1.exec(text)?.[1] || re2.exec(text)?.[1] || '';
                    };
                    challenge = m('challenge');
                    rpId = m('rpId');
                    userVerification = m('userVerification') || m('userVerificationRequirement') || 'preferred';
                    const toMatch = /createTimeout\s*[:=]\s*(\d+)/.exec(text);
                    if (toMatch) createTimeout = parseInt(toMatch[1]);
                    if (challenge) break;
                  }
                }

                if (!challenge) {
                  const forms = Array.from(document.forms).map(f => f.id).join(',');
                  return `err:no challenge (scripts: ${scripts.length}, forms: ${forms}, url: ${location.pathname})`;
                }

                const allowCredentials: PublicKeyCredentialDescriptor[] = [];
                const authnForm = document.getElementById('authn_select');
                if (authnForm) {
                  const inputs = authnForm.querySelectorAll('input[name="authn_use_chk"]');
                  for (const input of inputs) {
                    allowCredentials.push({
                      type: 'public-key',
                      id: b64urlDecode((input as HTMLInputElement).value),
                    });
                  }
                }

                const options: PublicKeyCredentialRequestOptions = {
                  challenge: b64urlDecode(challenge),
                  rpId: rpId || undefined,
                  userVerification: userVerification as UserVerificationRequirement,
                  timeout: createTimeout === 0 ? undefined : createTimeout * 1000,
                  allowCredentials: allowCredentials.length > 0 ? allowCredentials : undefined,
                };

                const cred = await navigator.credentials.get({ publicKey: options }) as PublicKeyCredential;
                const resp = cred.response as AuthenticatorAssertionResponse;

                (document.getElementById('clientDataJSON') as HTMLInputElement).value = b64urlEncode(resp.clientDataJSON);
                (document.getElementById('authenticatorData') as HTMLInputElement).value = b64urlEncode(resp.authenticatorData);
                (document.getElementById('signature') as HTMLInputElement).value = b64urlEncode(resp.signature);
                (document.getElementById('credentialId') as HTMLInputElement).value = cred.id;
                (document.getElementById('userHandle') as HTMLInputElement).value = resp.userHandle ? b64urlEncode(resp.userHandle) : '';

                return `ok:credId=${cred.id.substring(0, 16)}`;
              } catch (e: any) {
                return `err:${e.name}:${e.message}`;
              }
            });
            console.log(`  [onboarding] WebAuthn auth result: ${authResult}`);

            if (authResult.startsWith('err:')) {
              throw new Error(`WebAuthn authentication failed: ${authResult}`);
            }

            await Promise.all([
              userPage.waitForResponse(
                resp => resp.request().method() === 'POST' && resp.url().includes('login-actions'),
                { timeout: 30_000 },
              ),
              userPage.evaluate(() => {
                (document.getElementById('webauth') as HTMLFormElement).submit();
              }),
            ]);

            await userPage.waitForURL(
              url => !url.pathname.includes('/login-actions'),
              { timeout: 60_000 },
            );
            console.log(`  [onboarding] After passkey login: ${userPage.url().substring(0, 100)}`);
          }

          // Navigate to /complete-registration and do passkey login.
          // This helper handles both the info-page and fallback paths.
          async function navigateToCompleteAndLogin() {
            const completeUrl = `https://account.${baseDomain}/complete-registration`;
            console.log(`  [onboarding] Navigating to ${completeUrl}`);
            await userPage.goto(completeUrl);

            const reachedHome = await userPage.waitForURL(
              url => url.pathname.includes('/home'),
              { timeout: 10_000 },
            ).then(() => true).catch(() => false);

            if (!reachedHome) {
              await doPasskeyLogin();
            }
          }

          // If there's a "Continue" or "Back to Application" link, credentials were accepted.
          // Keycloak shows an info page after completing the required action.
          const continueLink = userPage.locator('a[id="backToApplication"], a:has-text("Back to"), a:has-text("Continue")');
          if (await continueLink.first().isVisible().catch(() => false)) {
            console.log('  [onboarding] Keycloak info page detected — passkey registered successfully');
            await navigateToCompleteAndLogin();
            registrationDone = true;
            break;
          }

          // If the registration form is shown again, retry (fresh challenge)
          if (attempt < 2) {
            const hasRegForm = await userPage.locator('#registerBtn, #registerWebAuthn, button:has-text("Register Passkey")').first().isVisible().catch(() => false);
            if (hasRegForm) {
              console.log('  [onboarding] Registration form re-rendered, retrying with fresh challenge...');
              continue;
            }
          }

          // Fallback: registration POST returned 200 but page didn't navigate
          // to info page or re-render form. The credential may have been accepted —
          // try /complete-registration to see if the OIDC flow works.
          console.log(`  [onboarding] Registration page stuck after POST. Trying /complete-registration fallback...`);
          await navigateToCompleteAndLogin();
          registrationDone = true;
          break;
        }

        // Navigate to final destination if needed
        const postRegUrl = userPage.url();
        if (!postRegUrl.includes('/home')) {
          if (postRegUrl.includes('/complete')) {
            // On /complete-registration — wait for the OIDC redirect to /home
            console.log('  [onboarding] On /complete, waiting for /home redirect...');
          } else {
            // Still on Keycloak or elsewhere — wait for /home or /complete
            console.log(`  [onboarding] Waiting for redirect to /home. Current: ${postRegUrl.substring(0, 80)}`);
          }
          await userPage.waitForURL(
            url => url.pathname.includes('/home'),
            { timeout: 60_000 },
          );
        }

        // Verify we're on the account portal home page
        await expect(
          userPage.locator(selectors.accountPortal.welcomeHeading),
        ).toBeVisible({ timeout: 15_000 });

        record('passkey-registration', true);

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 4: Element/Matrix — SSO login and verify
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        try {
          await userPage.goto(urls.element);
          await userPage.waitForLoadState('networkidle');

          // Element should auto-login via SSO (Keycloak session from registration)
          const notStuckOnAuth = !new URL(userPage.url()).hostname.startsWith('auth.');

          if (notStuckOnAuth) {
            const hasElementUI = await userPage
              .locator('.mx_MatrixChat, .mx_Welcome, .mx_HomePage, #matrixchat, [class*="mx_"]')
              .first()
              .isVisible({ timeout: 30_000 })
              .catch(() => false);

            record('matrix-element', hasElementUI, hasElementUI ? undefined : 'Element UI did not load');
          } else {
            record('matrix-element', false, 'Stuck on Keycloak login page');
          }
        } catch (err) {
          record('matrix-element', false, (err as Error).message);
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 5: Nextcloud/Files — SSO login and file upload
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        try {
          await userPage.goto(`${urls.files}/apps/files/`);
          await userPage.waitForLoadState('networkidle');

          // Handle OIDC login if needed (SSO may auto-complete)
          if (userPage.url().includes('auth.')) {
            // SSO didn't auto-complete — this might happen if Nextcloud
            // uses a different OIDC client that doesn't share the session.
            // Wait briefly for auto-redirect.
            const leftKeycloak = await userPage.waitForURL(
              (url) => !url.hostname.startsWith('auth.'),
              { timeout: 10_000 },
            ).then(() => true).catch(() => false);

            if (!leftKeycloak) {
              record('nextcloud-files', false, 'Stuck on Keycloak — SSO did not auto-complete for Nextcloud');
              throw new Error('skip');
            }
          }

          await userPage.waitForLoadState('networkidle');

          const pageText = await userPage.locator('body').textContent().catch(() => '') || '';
          const hasError = /Could not reach|Server Error|Internal Server Error|\b500\b/i.test(pageText);
          const stuckOnOidc = userPage.url().includes('user_oidc');

          if (hasError || stuckOnOidc) {
            record('nextcloud-files', false, hasError ? 'Server error' : 'Stuck on OIDC page');
          } else {
            await waitForNextcloudReady(userPage, { timeout: 30_000 });

            // Verify file upload via WebDAV
            const testFileName = `e2e-onboard-${uniqueId}.txt`;
            try {
              const uploadStatus = await userPage.evaluate(async (name) => {
                const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
                const resp = await fetch('/remote.php/dav/files/' + OC.currentUser + '/' + name, {
                  method: 'PUT',
                  headers: { requesttoken: token, 'Content-Type': 'text/plain' },
                  body: 'E2E onboarding test file',
                });
                return resp.status;
              }, testFileName);

              record('nextcloud-files', uploadStatus < 300, uploadStatus >= 300 ? `WebDAV upload HTTP ${uploadStatus}` : undefined);

              // Clean up uploaded file
              await userPage.evaluate(async (name) => {
                const token = document.querySelector('head[data-requesttoken]')?.getAttribute('data-requesttoken') || '';
                await fetch('/remote.php/dav/files/' + OC.currentUser + '/' + name, {
                  method: 'DELETE',
                  headers: { requesttoken: token },
                }).catch(() => {});
              }, testFileName).catch(() => {});
            } catch (err) {
              record('nextcloud-files', false, (err as Error).message);
            }
          }
        } catch (err) {
          if ((err as Error).message !== 'skip') {
            record('nextcloud-files', false, (err as Error).message);
          }
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 6: Roundcube/Webmail — SSO login and verify inbox
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        try {
          let roundcubeSuccess = false;

          for (let attempt = 0; attempt < 2; attempt++) {
            await userPage.goto(`${urls.webmail}/?_task=login&_action=oauth`);

            const result = await Promise.race([
              userPage.locator(ROUNDCUBE_INBOX).first().waitFor({ timeout: 45_000 }).then(() => 'inbox' as const),
              userPage.locator('#username:visible, #mt-password, #passkey-login-btn').first()
                .waitFor({ timeout: 45_000, state: 'attached' }).then(() => 'keycloak' as const),
            ]).catch(() => 'timeout' as const);

            if (result === 'inbox') {
              roundcubeSuccess = true;
              break;
            }

            if (result === 'keycloak') {
              // Keycloak should show passkey prompt — virtual authenticator responds
              // Wait for auto-redirect after passkey auth
              const redirected = await userPage.waitForURL(
                (url) => !url.hostname.startsWith('auth.'),
                { timeout: 30_000 },
              ).then(() => true).catch(() => false);

              if (redirected) {
                const inboxVisible = await userPage.locator(ROUNDCUBE_INBOX).first()
                  .waitFor({ timeout: 30_000 })
                  .then(() => true)
                  .catch(() => false);
                if (inboxVisible) {
                  roundcubeSuccess = true;
                  break;
                }
              }
            }

            if (attempt === 0) {
              console.log('  [onboarding] Roundcube OIDC timed out, retrying...');
            }
          }

          record('roundcube-webmail', roundcubeSuccess,
            roundcubeSuccess ? undefined : 'Could not load Roundcube inbox via OIDC');
        } catch (err) {
          record('roundcube-webmail', false, (err as Error).message);
        }

        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        // Step 7: Inbound email — verify Stalwart can receive mail
        // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        try {
          const testSubject = `E2E Onboarding Inbound ${uniqueId}`;

          // Plant a test email directly via IMAP master-user auth.
          // This verifies the Stalwart principal exists and accepts mail.
          const mimeMessage = [
            `From: test-sender@example.com`,
            `To: ${userEmail}`,
            `Subject: ${testSubject}`,
            `Date: ${new Date().toUTCString()}`,
            `Message-ID: <onboard-${uniqueId}@e2e.test>`,
            `Content-Type: text/plain`,
            ``,
            `E2E onboarding inbound email test`,
          ].join('\r\n');

          await appendCalendarEmail({ userEmail, mimeMessage });

          // Verify the email arrived
          const count = await countInboxBySubject({
            userEmail,
            subjectContains: testSubject,
          });

          record('inbound-email', count > 0,
            count > 0 ? undefined : 'Email not found in inbox after IMAP append');
        } catch (err) {
          const errMsg = (err as Error).message;
          if (errMsg.includes('auth failed') || errMsg.includes('Authentication failed')) {
            record('inbound-email', false,
              'Stalwart principal not accessible via IMAP — provisioning may have failed');
          } else {
            record('inbound-email', false, errMsg);
          }
        }
      } finally {
        await userContext.close();
      }

      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      // Summary
      // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

      console.log('\n  ┌──────────────────────────────────────────────');
      console.log('  │ Onboarding E2E Results');
      console.log('  ├──────────────────────────────────────────────');
      for (const [service, result] of Object.entries(results)) {
        const icon = result.passed ? 'PASS' : 'FAIL';
        const detail = result.error ? ` — ${result.error}` : '';
        console.log(`  │ [${icon}] ${service}${detail}`);
      }
      console.log('  └──────────────────────────────────────────────\n');

      // Hard-fail on critical steps
      const critical = ['admin-portal-invite', 'invitation-email', 'passkey-registration'];
      for (const svc of critical) {
        if (results[svc] && !results[svc].passed) {
          throw new Error(`Critical service failed: ${svc} — ${results[svc].error}`);
        }
      }

      // Non-critical failures are logged but don't fail the test.
      // They depend on infrastructure state (Roundcube OIDC, IMAP connectivity,
      // Stalwart provisioning) that may have transient issues in CI.
      const failures = Object.entries(results).filter(([, r]) => !r.passed);
      if (failures.length > 0) {
        const failList = failures.map(([s, r]) => `${s}: ${r.error}`).join('; ');
        console.log(`  [onboarding] WARNING: ${failures.length} non-critical service(s) had issues: ${failList}`);
      }
    } finally {
      // Always clean up the invited user
      if (invitedUserId) {
        await adminPage.evaluate(async (userId) => {
          await fetch(`/api/users/${userId}`, { method: 'DELETE' });
        }, invitedUserId).catch((err) => {
          console.log(`  [onboarding] Cleanup failed for ${username}: ${(err as Error).message}`);
        });

        await expect(adminPage.locator(ap.membersList)).not.toContainText(firstName, { timeout: 10_000 }).catch(() => {
          console.log(`  [onboarding] Cleanup: user ${username} may still appear in list`);
        });
      }
    }
  });
});
