<#--
    Platform WebAuthn Registration Page (used for both regular and passwordless)
    Keycloak 26.x uses webauthn-register.ftl for ALL WebAuthn registration flows.
    There is no separate webauthn-register-passwordless.ftl in the built-in themes.

    Includes magic-link fallback: when the device lacks a platform authenticator,
    shows an option to set up email-based sign-in instead.

    All styling uses inline styles + JS because the base template renders the
    "header" section inside an <h1> tag where <style> blocks don't reliably apply.
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
    <#if section = "header">
        ${realm.displayName!"the platform"}
    <#elseif section = "title">
        Set Up Your Passkey
    <#elseif section = "form">
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />

        <div style="text-align: center; padding: 2.5rem 2rem 1.5rem;">
            <h1 style="font-family: 'Figtree', sans-serif; font-size: 2.5rem; font-weight: 600; color: #A7AE8D; margin: 0 0 0.5rem 0; letter-spacing: 0.03em;">
                ${realm.displayName!"the platform"}
            </h1>
            <p style="font-family: 'Figtree', sans-serif; font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400;">
                Complete your account setup
            </p>
        </div>

        <div style="padding: 0 2rem 2.5rem; text-align: center;">
            <div style="width: 64px; height: 64px; margin: 0 auto 1.5rem; background: #EDF3EB; border-radius: 50%; display: flex; align-items: center; justify-content: center;">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" style="width: 32px; height: 32px; fill: #A7AE8D;">
                    <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>
                </svg>
            </div>

            <h2 style="font-size: 1.5rem; font-weight: 500; color: #A7AE8D; margin: 0 0 1rem 0; font-family: 'Figtree', sans-serif;">
                Set Up Your Passkey
            </h2>

            <p style="color: #6b6b6b; margin-bottom: 2rem; line-height: 1.6; font-family: 'Figtree', sans-serif;">
                To secure your account, you'll need to register a passkey.
                This can be your device's fingerprint, face recognition, or a security key.
            </p>

            <form id="register" action="${url.loginAction}" method="post">
                <div style="margin-bottom: 1.5rem; text-align: left;">
                    <label for="registerWebAuthnLabel" style="display: block; margin-bottom: 0.5rem; color: #6b6b6b; font-weight: 500; font-family: 'Figtree', sans-serif;">
                        Passkey Label
                    </label>
                    <input type="text" id="registerWebAuthnLabel" name="registerWebAuthnLabel"
                           value="Passkey"
                           placeholder="e.g., MacBook Touch ID"
                           style="width: 100%; padding: 0.75rem 1rem; border: 1px solid #d1d5db; border-radius: 8px; font-size: 1rem; box-sizing: border-box;" />
                </div>

                <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
                <input type="hidden" id="attestationObject" name="attestationObject"/>
                <input type="hidden" id="publicKeyCredentialId" name="publicKeyCredentialId"/>
                <input type="hidden" id="authenticatorLabel" name="authenticatorLabel"/>
                <input type="hidden" id="transports" name="transports"/>
                <input type="hidden" id="error" name="error"/>
            </form>

            <div id="no-platform-auth-banner" style="display:none; background: #fff7ed; border: 1px solid #fed7aa; border-radius: 8px; padding: 1rem 1.25rem; margin-bottom: 1.5rem; text-align: left;">
                <div style="font-weight: 600; color: #9a3412; margin-bottom: 0.25rem; font-size: 0.95rem;">Passkey not available on this device</div>
                <div style="color: #9a3412; font-size: 0.9rem; line-height: 1.5;">
                    Your device doesn't support passkeys (fingerprint or face recognition).
                    You can sign in using a secure link sent to your email instead.
                </div>
            </div>

            <button type="button" id="registerBtn" onclick="registerWebAuthn()"
                    style="width: 100%; padding: 1rem 2rem; background: #A7AE8D; color: white; border: none; border-radius: 8px; font-size: 1rem; font-weight: 500; cursor: pointer; font-family: 'Figtree', sans-serif;">
                Register Passkey
            </button>

            <a id="magic-link-btn" href="#"
               style="display:none; width: 100%; padding: 1rem 2rem; background: #A7AE8D; color: white; border: none; border-radius: 8px; font-size: 1rem; font-weight: 500; cursor: pointer; text-align: center; text-decoration: none; box-sizing: border-box; font-family: 'Figtree', sans-serif;">
                Set Up Email Sign-In
            </a>

            <div id="register-btn-secondary" style="display:none; text-align: center; margin-top: 0.75rem;">
                <a href="javascript:void(0)" onclick="registerWebAuthn()"
                   style="color: #6b6b6b; text-decoration: none; font-size: 0.9rem; font-family: 'Figtree', sans-serif;">
                    I have a security key &mdash; register passkey anyway
                </a>
            </div>

            <#if !isSetRetry?has_content && isAppInitiatedAction?has_content>
                <div style="text-align: center; margin-top: 1.5rem;">
                    <form action="${url.loginAction}" method="post">
                        <input type="hidden" id="isSetRetry" name="isSetRetry" value="true"/>
                        <a href="javascript:void(0)" onclick="this.parentNode.submit()"
                           style="color: #6b6b6b; text-decoration: none; font-size: 0.9rem; font-family: 'Figtree', sans-serif;">
                            Skip for now
                        </a>
                    </form>
                </div>
            </#if>
        </div>

        <#-- Page styling script — isolated from WebAuthn code -->
        <script type="text/javascript">
            document.documentElement.style.cssText += 'background: #F3E8D6 !important; background-image: none !important;';
            document.body.style.cssText += 'background: #F3E8D6 !important; background-image: none !important; min-height: 100vh;';

            var loginPage = document.querySelector('.login-pf-page');
            if (loginPage) loginPage.style.cssText += 'background: #F3E8D6 !important; display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; padding: 2rem !important; background-image: none !important;';

            var card = document.querySelector('.card-pf') || document.querySelector('.pf-c-login__main');
            if (card) card.style.cssText += 'background: rgba(255,255,255,0.95) !important; border-radius: 16px !important; box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important; padding: 0 !important; max-width: 500px !important; margin: 0 auto !important; border: none !important;';

            // Hide base template elements
            ['#kc-header', '.login-pf-page-header', '#kc-header-wrapper',
             '.login-pf-header', '#kc-info', '#kc-info-wrapper'].forEach(function(sel) {
                var el = document.querySelector(sel);
                if (el) el.style.display = 'none';
            });
        </script>

        <script type="text/javascript" src="${url.resourcesCommonPath}/node_modules/jquery/dist/jquery.min.js"></script>
        <script type="text/javascript">
            function registerWebAuthn() {
                var challenge = "${challenge}";
                var userid = "${userid}";
                var username = "${username}";
                var signatureAlgorithms = [<#list signatureAlgorithms as alg>${alg?c},</#list>];
                var rpEntityName = "${rpEntityName}";
                var rpId = "${rpId}";
                var attestationConveyancePreference = "${attestationConveyancePreference}";
                var authenticatorAttachment = "${authenticatorAttachment}";
                var requireResidentKey = "${requireResidentKey}";
                var userVerificationRequirement = "${userVerificationRequirement}";
                var createTimeout = ${createTimeout};
                var excludeCredentialIds = "${excludeCredentialIds}";
                var initLabel = document.getElementById('registerWebAuthnLabel').value;

                var pubKeyCredParams = [];
                for (var i = 0; i < signatureAlgorithms.length; i++) {
                    pubKeyCredParams.push({type: "public-key", alg: signatureAlgorithms[i]});
                }

                var excludeCredentials = [];
                if (excludeCredentialIds !== "") {
                    var excludeCredentialIdsList = excludeCredentialIds.split(',');
                    for (var i = 0; i < excludeCredentialIdsList.length; i++) {
                        excludeCredentials.push({
                            type: "public-key",
                            id: base64url.decode(excludeCredentialIdsList[i], {loose: true})
                        });
                    }
                }

                var publicKey = {
                    challenge: base64url.decode(challenge, {loose: true}),
                    rp: {id: rpId, name: rpEntityName},
                    user: {
                        id: base64url.decode(userid, {loose: true}),
                        name: username,
                        displayName: username
                    },
                    pubKeyCredParams: pubKeyCredParams,
                    authenticatorSelection: {
                        authenticatorAttachment: authenticatorAttachment === "not specified" ? undefined : authenticatorAttachment,
                        requireResidentKey: requireResidentKey === "Yes",
                        residentKey: requireResidentKey === "Yes" ? "required" : "discouraged",
                        userVerification: userVerificationRequirement
                    },
                    timeout: createTimeout === 0 ? undefined : createTimeout * 1000,
                    attestation: attestationConveyancePreference,
                    excludeCredentials: excludeCredentials
                };

                navigator.credentials.create({publicKey: publicKey})
                    .then(function(result) {
                        var clientDataJSON = result.response.clientDataJSON;
                        var attestationObject = result.response.attestationObject;
                        var publicKeyCredentialId = result.id;

                        document.getElementById('clientDataJSON').value = base64url.encode(new Uint8Array(clientDataJSON), {pad: false});
                        document.getElementById('attestationObject').value = base64url.encode(new Uint8Array(attestationObject), {pad: false});
                        document.getElementById('publicKeyCredentialId').value = publicKeyCredentialId;
                        document.getElementById('authenticatorLabel').value = initLabel;

                        var transports = result.response.getTransports ? result.response.getTransports() : [];
                        document.getElementById('transports').value = transports.join(',');

                        document.getElementById('register').submit();
                    })
                    .catch(function(err) {
                        document.getElementById('error').value = err.name + ": " + err.message;
                        document.getElementById('register').submit();
                    });
            }
        </script>
        <script type="text/javascript" src="${url.resourcesCommonPath}/node_modules/base64url/dist/base64url.min.js"></script>
        <script type="text/javascript">
            // Detect whether this device has a platform authenticator (Touch ID, Windows Hello, etc.)
            // If not, show the magic-link alternative for email-based sign-in.
            (function detectPlatformAuthenticator() {
                if (typeof PublicKeyCredential === 'undefined' ||
                    typeof PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable !== 'function') {
                    showMagicLinkOption();
                    return;
                }
                PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
                    .then(function(available) {
                        if (!available) {
                            showMagicLinkOption();
                        }
                    })
                    .catch(function() {
                        // Detection failed — keep normal passkey UI
                    });
            })();

            function showMagicLinkOption() {
                document.getElementById('no-platform-auth-banner').style.display = 'block';
                document.getElementById('magic-link-btn').style.display = 'block';
                document.getElementById('registerBtn').style.display = 'none';
                document.getElementById('register-btn-secondary').style.display = 'block';

                // Build the switch URL from the mt-setup-info cookie (set by /beginSetup)
                var magicBtn = document.getElementById('magic-link-btn');
                try {
                    var cookies = document.cookie.split(';');
                    for (var i = 0; i < cookies.length; i++) {
                        var c = cookies[i].trim();
                        if (c.indexOf('mt-setup-info=') === 0) {
                            var payload = JSON.parse(atob(c.substring('mt-setup-info='.length).replace(/-/g, '+').replace(/_/g, '/')));
                            var accountHost = window.location.hostname.replace(/^auth\./, 'account.');
                            var currentUrl = window.location.href;
                            magicBtn.href = 'https://' + accountHost + '/switch-to-magic-link'
                                + '?userId=' + encodeURIComponent(payload.userId)
                                + '&token=' + encodeURIComponent(payload.token)
                                + '&next=' + encodeURIComponent(currentUrl);
                            return;
                        }
                    }
                } catch(e) {
                    // Cookie not found or invalid — hide the magic link button
                    magicBtn.style.display = 'none';
                    document.getElementById('no-platform-auth-banner').style.display = 'none';
                    document.getElementById('registerBtn').style.display = 'block';
                    document.getElementById('register-btn-secondary').style.display = 'none';
                }
            }
        </script>
    </#if>
</@layout.registrationLayout>
