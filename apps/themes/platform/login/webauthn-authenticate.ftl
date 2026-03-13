<#--
    Platform WebAuthn Authentication Page (used for both regular and passwordless)
    Keycloak 26.x uses webauthn-authenticate.ftl for ALL WebAuthn authentication flows.
    There is no separate webauthn-authenticate-passwordless.ftl in the built-in themes.

    All styling uses inline styles + JS because the base template renders the
    "header" section inside an <h1> tag where <style> blocks don't reliably apply.
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('') displayRequiredFields=false; section>
    <#if section = "header">
        ${realm.displayName!"the platform"}
    <#elseif section = "form">
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />

        <div style="text-align: center; padding: 2.5rem 2rem 1.5rem;">
            <h1 style="font-family: 'Figtree', sans-serif; font-size: 2.5rem; font-weight: 600; color: #A7AE8D; margin: 0 0 0.5rem 0; letter-spacing: 0.03em;">
                ${realm.displayName!"the platform"}
            </h1>
            <p style="font-family: 'Figtree', sans-serif; font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400;">
                Sign in with your passkey
            </p>
        </div>

        <div style="padding: 0 2rem 2.5rem; text-align: center;">
            <div style="font-size: 4rem; margin-bottom: 1rem;">🔐</div>

            <div style="font-family: 'Figtree', sans-serif; font-size: 1rem; color: #6b6b6b; margin-bottom: 1.5rem; line-height: 1.5;">
                Use your passkey to sign in securely. Your device will prompt you for biometrics or your security key.
            </div>

            <form id="webauth" action="${url.loginAction}" method="post">
                <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
                <input type="hidden" id="authenticatorData" name="authenticatorData"/>
                <input type="hidden" id="signature" name="signature"/>
                <input type="hidden" id="credentialId" name="credentialId"/>
                <input type="hidden" id="userHandle" name="userHandle"/>
                <input type="hidden" id="error" name="error"/>

                <button type="button" id="authenticateWebAuthnButton"
                    style="display: inline-flex; align-items: center; justify-content: center; gap: 0.75rem;
                           padding: 1rem 2rem; background: #A7AE8D; border: none; border-radius: 8px;
                           color: #fff; font-size: 1.1rem; font-weight: 500; cursor: pointer;
                           box-shadow: 0 4px 12px rgba(167, 174, 141, 0.3); width: 100%; max-width: 320px;
                           font-family: 'Figtree', sans-serif; transition: all 0.2s ease;">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                    </svg>
                    Sign in with Passkey
                </button>
            </form>

            <#if authenticators??>
                <form id="authn_select" style="display:none;">
                    <#list authenticators.authenticators as authenticator>
                        <input type="hidden" name="authn_use_chk" value="${authenticator.credentialId}"/>
                    </#list>
                </form>
            </#if>

            <#-- "Try another way" link — shown when alternative authenticators exist (e.g. magic link, password) -->
            <#if auth?has_content && auth.showTryAnotherWayLink()>
            <div style="margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #eee; font-family: 'Figtree', sans-serif;">
                <form id="kc-select-try-another-way-form" action="${url.loginAction}" method="post">
                    <input type="hidden" name="tryAnotherWay" value="on"/>
                    <a href="#" id="try-another-way"
                       onclick="document.getElementById('kc-select-try-another-way-form').submit();return false;"
                       style="color: #A7AE8D; text-decoration: none; font-size: 0.95rem; font-weight: 500;">
                        ${msg("doTryAnotherWay","Try another way")}
                    </a>
                </form>
            </div>
            </#if>

            <div style="margin-top: <#if auth?has_content && auth.showTryAnotherWayLink()>0.5rem<#else>1.5rem</#if>; <#if !(auth?has_content && auth.showTryAnotherWayLink())>padding-top: 1rem; border-top: 1px solid #eee; </#if>font-family: 'Figtree', sans-serif;">
                <a href="#" id="recover-link" style="color: #6b6b6b; text-decoration: none; font-size: 0.9rem;">Lost your passkey?</a>
            </div>

            <div style="margin-top: 0.5rem; font-family: 'Figtree', sans-serif;">
                <a href="#" id="guest-register-link" style="color: #6b6b6b; text-decoration: none; font-size: 0.9rem;">Guest? Register here</a>
            </div>
        </div>

        <#-- Separate script for page styling — isolated from WebAuthn code -->
        <script type="text/javascript">
            document.documentElement.style.cssText += 'background: #F3E8D6 !important; background-image: none !important;';
            document.body.style.cssText += 'background: #F3E8D6 !important; background-image: none !important; min-height: 100vh;';

            var loginPage = document.querySelector('.login-pf-page');
            if (loginPage) loginPage.style.cssText += 'background: #F3E8D6 !important; display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; padding: 2rem !important; background-image: none !important;';

            var card = document.querySelector('.card-pf') || document.querySelector('.pf-c-login__main');
            if (card) card.style.cssText += 'background: rgba(255,255,255,0.95) !important; border-radius: 16px !important; box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important; padding: 0 !important; max-width: 480px !important; margin: 0 auto !important; border: none !important;';

            // Hide base template elements
            ['#kc-header', '.login-pf-page-header', '#kc-header-wrapper', '#kc-username',
             '.kc-username', '#kc-attempted-username', '.pf-c-login__main-header',
             '.login-pf-header'].forEach(function(sel) {
                var el = document.querySelector(sel);
                if (el) el.style.display = 'none';
            });

            document.querySelectorAll('a').forEach(function(a) {
                if (a.textContent.trim() === 'Restart login' || a.id === 'reset-login') {
                    var p = a.closest('div') || a.parentElement;
                    if (p && !p.querySelector('#authenticateWebAuthnButton')) p.style.display = 'none';
                }
            });
        </script>

        <script type="module">
            <#outputformat "JavaScript">
            import { authenticateByWebAuthn } from "${url.resourcesPath}/js/webauthnAuthenticate.js";
            const authButton = document.getElementById('authenticateWebAuthnButton');
            authButton.addEventListener("click", function() {
                const input = {
                    isUserIdentified : ${isUserIdentified},
                    challenge : ${challenge?c},
                    userVerification : ${userVerification?c},
                    rpId : ${rpId?c},
                    createTimeout : ${createTimeout?c},
                    errmsg : ${msg("webauthn-unsupported-browser-text")?c}
                };
                authenticateByWebAuthn(input);
            }, { once: true });
            </#outputformat>
        </script>

        <script type="text/javascript">
            // Auto-trigger passkey prompt on page load
            if (window.PublicKeyCredential && document.hasFocus()) {
                PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()
                    .then(function(available) {
                        if (available) {
                            setTimeout(function() {
                                document.getElementById('authenticateWebAuthnButton').click();
                            }, 500);
                        }
                    })
                    .catch(function() {
                        // Silently skip auto-trigger — user can still tap the button
                    });
            }

            // Set up recovery link - points to admin portal's /recover page
            var recoverLink = document.getElementById('recover-link');
            if (recoverLink) {
                var currentHost = window.location.hostname;
                var adminHost = currentHost.replace(/^auth\./, 'admin.');
                recoverLink.href = 'https://' + adminHost + '/recover';
            }

            // Set up guest registration link
            var guestRegisterLink = document.getElementById('guest-register-link');
            if (guestRegisterLink) {
                var currentHost = window.location.hostname;
                var adminHost = currentHost.replace(/^auth\./, 'admin.');
                guestRegisterLink.href = 'https://' + adminHost + '/register';
            }
        </script>
    </#if>
</@layout.registrationLayout>
