<#--
    Platform Login - Username Entry Step
    Rendered by auth-username-form authenticator in the passkey browser flow.
    After username submission, Keycloak proceeds to the credential subflow
    (WebAuthn Passwordless / Magic Link / Password Form).

    Login method visibility is driven by realm attributes set by import-keycloak-realm.sh
    from features.login_methods in tenant config:
      mt.login.passkey       — show Passkey button (default true)
      mt.login.magic_link    — show Magic Link option (default true)
      mt.login.google_sso    — show Google SSO button (default false)

    When only google_sso is enabled the username form is hidden entirely; clicking the
    Google button bypasses the username step via the IdP redirect URL.
-->
<#assign loginPasskey   = ((realm.attributes['mt.login.passkey'])!"true") == "true">
<#assign loginMagicLink = ((realm.attributes['mt.login.magic_link'])!"true") == "true">
<#assign loginGoogleSso = ((realm.attributes['mt.login.google_sso'])!"false") == "true">
<#assign onlyGoogleSso  = loginGoogleSso && !loginPasskey && !loginMagicLink>
<#assign showSideBySide = loginPasskey && loginGoogleSso>
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('username') displayRequiredFields=false; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <style>
            /* Override styles.css hiding rules — this IS the primary login form, not the admin toggle */
            form#kc-form-login,
            form[id="kc-form-login"],
            #kc-form-login {
                display: block !important;
            }
            input#username,
            input[name="username"],
            label[for="username"],
            #kc-form-buttons {
                display: block !important;
            }

            /* Override Keycloak background - matching platform cream */
            html.login-pf, html.login-pf body, body, .login-pf-page {
                background: #F3E8D6 !important;
                background-image: none !important;
                min-height: 100vh !important;
            }
            .login-pf-page-header { display: none !important; }
            .card-pf { background: transparent !important; box-shadow: none !important; border: none !important; }

            /* Center content container */
            .login-pf-page {
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                justify-content: center !important;
                padding: 2rem !important;
            }

            /* Unified card container */
            .card-pf, .login-pf-page .card-pf {
                background: rgba(255,255,255,0.9) !important;
                border-radius: 16px !important;
                box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important;
                padding: 0 !important;
                max-width: 420px !important;
                margin: 0 auto !important;
            }

            .platform-header {
                text-align: center;
                padding: 2.5rem 2rem 1.5rem;
                background: transparent;
            }
            .platform-title {
                font-family: 'Figtree', sans-serif;
                font-size: 2.5rem; font-weight: 600; color: #A7AE8D;
                margin: 0 0 0.5rem 0; letter-spacing: 0.03em;
            }
            .platform-welcome {
                font-family: 'Figtree', sans-serif;
                font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400;
            }

            /* Login options container */
            .login-options {
                padding: 0 2rem 2.5rem;
            }

            /* Username display / form */
            .username-section {
                margin-bottom: 1.5rem;
            }
            .username-section label {
                display: block;
                font-family: 'Figtree', sans-serif;
                font-size: 0.9rem;
                color: #6b6b6b;
                margin-bottom: 0.5rem;
            }
            .username-section input[type="text"] {
                display: block;
                width: 100%;
                padding: 0.75rem 1rem;
                border: 1px solid #ddd;
                border-radius: 8px;
                font-size: 1rem;
                font-family: 'Figtree', sans-serif;
                box-sizing: border-box;
            }
            .username-section input[type="text"]:focus {
                outline: none;
                border-color: #A7AE8D;
                box-shadow: 0 0 0 3px rgba(167, 174, 141, 0.1);
            }
            .readonly-username {
                display: flex;
                align-items: center;
                gap: 0.5rem;
                padding: 0.75rem 1rem;
                background: #f5f5f5;
                border: 1px solid #ddd;
                border-radius: 8px;
                font-family: 'Figtree', sans-serif;
                font-size: 1rem;
                color: #333;
            }
            .readonly-username .not-you {
                font-size: 0.85rem;
                color: #A7AE8D;
                text-decoration: none;
                white-space: nowrap;
            }
            .readonly-username .not-you:hover {
                text-decoration: underline;
            }

            /* Continue button (passkey or generic primary) */
            .continue-btn {
                display: flex !important;
                align-items: center;
                justify-content: center;
                gap: 0.75rem;
                width: 100%;
                padding: 1rem 2rem !important;
                background: #A7AE8D !important;
                border: none !important;
                border-radius: 8px !important;
                color: #fff !important;
                font-size: 1.1rem !important;
                font-weight: 500 !important;
                cursor: pointer !important;
                transition: all 0.2s ease !important;
                box-shadow: 0 4px 12px rgba(167, 174, 141, 0.3) !important;
                text-decoration: none;
            }
            .continue-btn:hover {
                background: #8A9475 !important;
                transform: translateY(-2px);
                box-shadow: 0 6px 16px rgba(167, 174, 141, 0.4) !important;
                color: #fff !important;
                text-decoration: none;
            }

            /* Side-by-side login methods row (passkey + google) */
            .login-methods-row {
                display: flex;
                flex-direction: row;
                gap: 0.75rem;
                width: 100%;
            }
            .login-methods-row .continue-btn,
            .login-methods-row .google-btn {
                flex: 1 1 0;
                padding: 1rem 0.75rem !important;
                font-size: 1rem !important;
            }

            /* Google sign-in button (white background, dark text, Google brand) */
            .google-btn {
                display: flex !important;
                align-items: center;
                justify-content: center;
                gap: 0.65rem;
                width: 100%;
                padding: 1rem 2rem !important;
                background: #fff !important;
                border: 1px solid #dadce0 !important;
                border-radius: 8px !important;
                color: #3c4043 !important;
                font-size: 1.1rem !important;
                font-weight: 500 !important;
                cursor: pointer !important;
                transition: all 0.2s ease !important;
                box-shadow: 0 1px 3px rgba(0,0,0,0.08) !important;
                text-decoration: none;
            }
            .google-btn:hover {
                background: #f8f9fa !important;
                box-shadow: 0 4px 12px rgba(0,0,0,0.12) !important;
                color: #3c4043 !important;
                text-decoration: none;
                transform: translateY(-2px);
            }
            .google-btn svg { width: 20px; height: 20px; flex-shrink: 0; }

            /* Remember Me checkbox styling */
            .remember-me-container {
                display: flex;
                justify-content: center;
                margin-top: 1.5rem;
                padding-top: 1rem;
            }
            .remember-me-label {
                display: flex;
                align-items: center;
                gap: 0.5rem;
                font-family: 'Figtree', sans-serif;
                font-size: 0.95rem;
                color: #6b6b6b;
                cursor: pointer;
            }
            .remember-me-label input[type="checkbox"] {
                width: 18px;
                height: 18px;
                accent-color: #A7AE8D;
                cursor: pointer;
            }
            .remember-me-label span {
                user-select: none;
            }

            /* Recovery / guest links */
            .bottom-links {
                text-align: center;
                margin-top: 1rem;
            }
            .bottom-links a {
                color: #6b6b6b;
                font-family: 'Figtree', sans-serif;
                font-size: 0.9rem;
                text-decoration: none;
            }
            .bottom-links a:hover {
                color: #A7AE8D;
                text-decoration: underline;
            }

            /* Style form submit buttons */
            #kc-form-buttons input[type="submit"],
            .pf-c-button {
                display: inline-block !important;
                padding: 0.75rem 2rem !important;
                background: #A7AE8D !important;
                border: none !important;
                border-radius: 8px !important;
                color: #fff !important;
                font-size: 1rem !important;
                font-weight: 500 !important;
                cursor: pointer !important;
                transition: all 0.2s ease !important;
            }
            #kc-form-buttons input[type="submit"]:hover,
            .pf-c-button:hover {
                background: #8A9475 !important;
            }
            hr, .kc-divider-text { display: none !important; }
            .pf-c-login__footer, .login-pf-page-footer { background: transparent !important; }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realm.displayName!"the platform"}</h1>
            <p class="platform-welcome">Please login to continue</p>
        </div>
    <#elseif section = "form">
        <#-- Pick a Google IdP provider entry (if any) — used to render the SSO button -->
        <#assign googleProvider = {}>
        <#if loginGoogleSso && social.providers??>
            <#list social.providers as p>
                <#if p.alias == "google">
                    <#assign googleProvider = p>
                </#if>
            </#list>
        </#if>

        <div class="login-options">
            <#-- Error messages (e.g. user not found, invalid credentials) -->
            <#if message?has_content && (message.type != 'warning' || !isAppInitiatedAction??)>
                <div class="alert alert-${message.type}" style="
                    padding: 0.75rem 1rem;
                    margin-bottom: 1rem;
                    border-radius: 8px;
                    font-family: 'Figtree', sans-serif;
                    font-size: 0.9rem;
                    <#if message.type = 'error'>background: #fef2f2; color: #991b1b; border: 1px solid #fecaca;</#if>
                    <#if message.type = 'warning'>background: #fffbeb; color: #92400e; border: 1px solid #fde68a;</#if>
                    <#if message.type = 'success'>background: #f0fdf4; color: #166534; border: 1px solid #bbf7d0;</#if>
                    <#if message.type = 'info'>background: #eff6ff; color: #1e40af; border: 1px solid #bfdbfe;</#if>
                ">
                    ${kcSanitize(message.summary)?no_esc}
                </div>
            </#if>

            <#if onlyGoogleSso>
                <#-- Google-only layout: no username field, single centered SSO button -->
                <#if googleProvider?has_content>
                    <a href="${googleProvider.loginUrl}" id="social-google" class="google-btn">
                        <svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
                            <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
                            <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
                            <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
                            <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
                        </svg>
                        Sign in with Google
                    </a>
                <#else>
                    <div class="alert alert-error" style="padding: 0.75rem 1rem; border-radius: 8px; background: #fef2f2; color: #991b1b; border: 1px solid #fecaca;">
                        Sign-in is temporarily unavailable. Please contact your administrator.
                    </div>
                </#if>
            <#else>
                <form id="kc-form-login" action="${url.loginAction}" method="post">
                    <div class="username-section">
                        <label for="username">Email</label>
                        <#if login.username?? && login.username?has_content>
                            <div class="readonly-username">
                                <span style="flex: 1;">${login.username}</span>
                                <a href="#" id="not-you-link" class="not-you">Not you?</a>
                            </div>
                            <input type="hidden" id="username" name="username" value="${login.username}" />
                        <#else>
                            <input tabindex="1" id="username" name="username" value="" type="text" autofocus autocomplete="username" placeholder="Enter your email" />
                        </#if>
                    </div>

                    <#-- Remember Me (default checked) -->
                    <#if realm.rememberMe>
                        <div class="remember-me-container">
                            <label class="remember-me-label">
                                <input tabindex="2" id="rememberMe" name="rememberMe" type="checkbox" checked>
                                <span>Remember me</span>
                            </label>
                        </div>
                    </#if>

                    <#-- Primary login buttons -->
                    <#if showSideBySide>
                        <div class="login-methods-row">
                            <button type="submit" tabindex="3" class="continue-btn">
                                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                                    <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                                </svg>
                                Passkey
                            </button>
                            <#if googleProvider?has_content>
                                <a href="${googleProvider.loginUrl}" id="social-google" class="google-btn">
                                    <svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
                                        <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
                                        <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
                                        <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
                                        <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
                                    </svg>
                                    Google
                                </a>
                            </#if>
                        </div>
                    <#elseif loginPasskey>
                        <button type="submit" tabindex="3" class="continue-btn">
                            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                                <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                            </svg>
                            Continue with Passkey
                        </button>
                    <#elseif loginMagicLink>
                        <#-- Magic-link only: submit form to credential subflow which sends the email -->
                        <button type="submit" tabindex="3" class="continue-btn">
                            Send sign-in link
                        </button>
                    </#if>
                </form>

                <#-- Recovery link (only when passkey is enabled) -->
                <#if loginPasskey>
                    <div class="bottom-links" style="margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #eee;">
                        <a href="#" id="recover-link">Lost your passkey?</a>
                    </div>
                </#if>

                <#-- Magic-link as a secondary text link, only when magic_link is enabled
                     AND there is at least one other primary button (passkey/google) — when
                     magic_link is the only method, the primary button above already handles it. -->
                <#if loginMagicLink && (loginPasskey || loginGoogleSso)>
                    <div class="bottom-links" style="margin-top: 0.5rem;">
                        <a href="#" id="magic-link-login">Sign in with email link</a>
                    </div>
                </#if>

                <#-- Guest registration link -->
                <div class="bottom-links" style="margin-top: 0.5rem;">
                    <a href="#" id="guest-register-link">Guest? Register here</a>
                </div>
            </#if>

            <#-- Policy links (always shown) -->
            <#if properties.privacyPolicyUrl?has_content || properties.termsOfUseUrl?has_content || properties.acceptableUsePolicyUrl?has_content>
            <div class="policy-footer" style="text-align: center; margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #eee; font-family: 'Figtree', sans-serif; font-size: 0.75rem; color: #999;">
                <#if properties.privacyPolicyUrl?has_content><a href="${properties.privacyPolicyUrl}" target="_blank" rel="noopener" style="color: #999; text-decoration: none; margin: 0 0.4rem;">Privacy Policy</a></#if>
                <#if properties.termsOfUseUrl?has_content><a href="${properties.termsOfUseUrl}" target="_blank" rel="noopener" style="color: #999; text-decoration: none; margin: 0 0.4rem;">Terms of Use</a></#if>
                <#if properties.acceptableUsePolicyUrl?has_content><a href="${properties.acceptableUsePolicyUrl}" target="_blank" rel="noopener" style="color: #999; text-decoration: none; margin: 0 0.4rem;">Acceptable Use Policy</a></#if>
            </div>
            </#if>
        </div>

        <script type="text/javascript">
            // "Not you?" link - clears pre-filled username and redirects to Keycloak logout
            var notYouLink = document.getElementById('not-you-link');
            if (notYouLink) {
                notYouLink.addEventListener('click', function(e) {
                    e.preventDefault();
                    var currentUrl = window.location.href;
                    var logoutUrl = currentUrl.replace(/\/realms\/([^/]+)\/.*/, '/realms/$1/protocol/openid-connect/logout')
                        + '?post_logout_redirect_uri=' + encodeURIComponent(currentUrl);
                    window.location.href = logoutUrl;
                });
            }

            // Intercept form submit: call account portal to ensure passkey credential
            // is ordered before password. This fixes Keycloak 26.5's
            // AuthenticationSelectionResolver picking password when it was created first.
            var loginForm = document.getElementById('kc-form-login');
            if (loginForm) {
                loginForm.addEventListener('submit', function(e) {
                    var emailInput = document.getElementById('username');
                    var email = emailInput ? emailInput.value : '';
                    if (!email) return; // Let Keycloak handle empty input validation

                    var accountHost = window.location.hostname.replace(/^auth\./, 'account.');
                    var apiUrl = 'https://' + accountHost + '/api/ensure-passkey-priority';

                    // Fire-and-forget — don't block the form submission.
                    // The API call races with Keycloak's processing. On a cache hit
                    // (credentials already correct) it's a no-op. On a fix, the call
                    // typically completes before Keycloak evaluates the credential
                    // subflow, but even if it loses the race, the NEXT login will work.
                    // Uses URLSearchParams so the Content-Type is
                    // application/x-www-form-urlencoded (CORS simple request, no preflight).
                    try {
                        navigator.sendBeacon(apiUrl, new URLSearchParams({ email: email }));
                    } catch (ignored) {}
                });
            }

            document.addEventListener('DOMContentLoaded', function() {
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

                // Set up magic-link login link
                var magicLinkLogin = document.getElementById('magic-link-login');
                if (magicLinkLogin) {
                    var accountHost = window.location.hostname.replace(/^auth\./, 'account.');
                    var magicLinkUrl = 'https://' + accountHost + '/magic-link-login';
                    // Preserve the original destination (e.g. files.*, docs.*) through the magic-link flow
                    try {
                        var params = new URLSearchParams(window.location.search);
                        var redirectUri = params.get('redirect_uri');
                        if (redirectUri) {
                            var appOrigin = new URL(redirectUri).origin;
                            var accountOrigin = 'https://' + accountHost;
                            if (appOrigin !== accountOrigin) {
                                magicLinkUrl += '?next=' + encodeURIComponent(appOrigin);
                            }
                        }
                    } catch (e) {}
                    magicLinkLogin.href = magicLinkUrl;
                }
            });
        </script>
    </#if>
</@layout.registrationLayout>
