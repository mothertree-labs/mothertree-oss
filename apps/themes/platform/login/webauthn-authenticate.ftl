<#--
    Platform WebAuthn Passwordless Authentication Page
    This page is shown when users authenticate with a passkey.
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('') displayRequiredFields=false; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <style>
            /* Override Keycloak background - matching platform cream */
            html.login-pf, html.login-pf body, body, .login-pf-page {
                background: #f2efe8 !important;
                background-image: none !important;
                min-height: 100vh !important;
            }
            .login-pf-page-header { display: none !important; }
            
            /* Center content container */
            .login-pf-page { 
                display: flex !important; 
                flex-direction: column !important;
                align-items: center !important; 
                justify-content: center !important;
                padding: 2rem !important;
            }
            
            /* Card styling */
            .card-pf, .login-pf-page .card-pf {
                background: rgba(255,255,255,0.95) !important;
                border-radius: 16px !important;
                box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important;
                padding: 0 !important;
                max-width: 480px !important;
                margin: 0 auto !important;
            }
            
            .platform-header { 
                text-align: center; 
                padding: 2.5rem 2rem 1.5rem;
                background: transparent;
            }
            .platform-title { 
                font-family: 'Tomorrow', sans-serif;
                font-size: 2.5rem; font-weight: 400; color: #4a6741; 
                margin: 0 0 0.5rem 0; letter-spacing: 0.03em;
            }
            .platform-welcome { 
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400; 
            }
            
            /* WebAuthn specific styles */
            .webauthn-auth-container {
                padding: 0 2rem 2.5rem;
                text-align: center;
            }
            
            .passkey-icon {
                font-size: 4rem;
                margin-bottom: 1rem;
            }
            
            .passkey-instructions {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1rem;
                color: #6b6b6b;
                margin-bottom: 1.5rem;
                line-height: 1.5;
            }
            
            /* Authenticate button */
            #authenticateWebAuthnButton, .webauthn-auth-btn {
                display: inline-flex !important;
                align-items: center;
                justify-content: center;
                gap: 0.75rem;
                padding: 1rem 2rem !important;
                background: #4a6741 !important;
                border: none !important;
                border-radius: 8px !important;
                color: #fff !important;
                font-size: 1.1rem !important;
                font-weight: 500 !important;
                cursor: pointer !important;
                transition: all 0.2s ease !important;
                box-shadow: 0 4px 12px rgba(74, 103, 65, 0.3) !important;
                width: 100%;
                max-width: 320px;
            }
            
            #authenticateWebAuthnButton:hover, .webauthn-auth-btn:hover {
                background: #3d5636 !important;
                transform: translateY(-2px);
                box-shadow: 0 6px 16px rgba(74, 103, 65, 0.4) !important;
            }
            
            /* Error messages */
            .alert-error {
                background: #fef2f2;
                border: 1px solid #fecaca;
                border-radius: 8px;
                padding: 1rem;
                margin-bottom: 1.5rem;
                color: #991b1b;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            /* Try another way link */
            .try-another-way {
                margin-top: 1.5rem;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            .try-another-way a {
                color: #4a6741;
                text-decoration: none;
            }
            
            .try-another-way a:hover {
                text-decoration: underline;
            }
            
            /* Recovery link */
            .recover-passkey {
                margin-top: 1.5rem;
                padding-top: 1rem;
                border-top: 1px solid #eee;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            .recover-passkey a {
                color: #6b6b6b;
                text-decoration: none;
                font-size: 0.9rem;
            }
            
            .recover-passkey a:hover {
                color: #4a6741;
                text-decoration: underline;
            }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Sign in with your passkey</p>
        </div>
    <#elseif section = "form">
        <div class="webauthn-auth-container">
            <div class="passkey-icon">🔐</div>
            
            <div class="passkey-instructions">
                Use your passkey to sign in securely. Your device will prompt you for biometrics or your security key.
            </div>
            
            <form id="webauthn-auth-form" action="${url.loginAction}" method="post">
                <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
                <input type="hidden" id="authenticatorData" name="authenticatorData"/>
                <input type="hidden" id="signature" name="signature"/>
                <input type="hidden" id="credentialId" name="credentialId"/>
                <input type="hidden" id="userHandle" name="userHandle"/>
                <input type="hidden" id="error" name="error"/>
                
                <button type="button" id="authenticateWebAuthnButton" class="webauthn-auth-btn">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                    </svg>
                    Sign in with Passkey
                </button>
            </form>
            
            <#if shouldDisplayAuthenticators?? && shouldDisplayAuthenticators>
                <div class="try-another-way">
                    <a href="${url.loginUrl}">Try another way</a>
                </div>
            </#if>
            
            <div class="recover-passkey">
                <a href="#" id="recover-link">Lost your passkey?</a>
            </div>

            <div class="recover-passkey" style="border-top: none; margin-top: 0.5rem; padding-top: 0;">
                <a href="#" id="guest-register-link">Guest? Register here</a>
            </div>
        </div>
        
        <script type="text/javascript">
            // WebAuthn authentication challenge from Keycloak
            var challenge = "${challenge}";
            var userVerification = "${userVerification}";
            var rpId = "${rpId}";
            var createTimeout = ${createTimeout};
            <#if authenticators??>
            var authenticators = [
                <#list authenticators.authenticators as authenticator>
                {
                    credentialId: "${authenticator.credentialId}",
                    transports: "${authenticator.transports}"
                }<#sep>,</#sep>
                </#list>
            ];
            <#else>
            var authenticators = [];
            </#if>
            
            function base64UrlToArrayBuffer(base64Url) {
                var base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
                var padding = '='.repeat((4 - base64.length % 4) % 4);
                var base64Padded = base64 + padding;
                var binary = atob(base64Padded);
                var bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) {
                    bytes[i] = binary.charCodeAt(i);
                }
                return bytes.buffer;
            }
            
            function arrayBufferToBase64Url(buffer) {
                var bytes = new Uint8Array(buffer);
                var binary = '';
                for (var i = 0; i < bytes.byteLength; i++) {
                    binary += String.fromCharCode(bytes[i]);
                }
                var base64 = btoa(binary);
                return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
            }
            
            function doAuthenticate() {
                var allowCredentials = [];
                
                for (var i = 0; i < authenticators.length; i++) {
                    var transports = authenticators[i].transports ? authenticators[i].transports.split(',') : [];
                    allowCredentials.push({
                        type: 'public-key',
                        id: base64UrlToArrayBuffer(authenticators[i].credentialId),
                        transports: transports.length > 0 ? transports : undefined
                    });
                }
                
                var publicKeyCredentialRequestOptions = {
                    challenge: base64UrlToArrayBuffer(challenge),
                    timeout: createTimeout === 0 ? 60000 : createTimeout,
                    userVerification: userVerification
                };
                
                if (rpId) {
                    publicKeyCredentialRequestOptions.rpId = rpId;
                }
                
                if (allowCredentials.length > 0) {
                    publicKeyCredentialRequestOptions.allowCredentials = allowCredentials;
                }
                
                navigator.credentials.get({publicKey: publicKeyCredentialRequestOptions})
                    .then(function(credential) {
                        var response = credential.response;
                        
                        document.getElementById('clientDataJSON').value = arrayBufferToBase64Url(response.clientDataJSON);
                        document.getElementById('authenticatorData').value = arrayBufferToBase64Url(response.authenticatorData);
                        document.getElementById('signature').value = arrayBufferToBase64Url(response.signature);
                        document.getElementById('credentialId').value = arrayBufferToBase64Url(credential.rawId);
                        
                        if (response.userHandle) {
                            document.getElementById('userHandle').value = arrayBufferToBase64Url(response.userHandle);
                        }
                        
                        document.getElementById('webauthn-auth-form').submit();
                    })
                    .catch(function(err) {
                        console.error('WebAuthn authentication error:', err);
                        document.getElementById('error').value = err.message || 'Authentication failed';
                        document.getElementById('webauthn-auth-form').submit();
                    });
            }
            
            document.getElementById('authenticateWebAuthnButton').addEventListener('click', doAuthenticate);
            
            // Auto-trigger passkey prompt on page load for better UX
            if (window.PublicKeyCredential) {
                // Small delay to ensure page is fully loaded
                setTimeout(doAuthenticate, 500);
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
