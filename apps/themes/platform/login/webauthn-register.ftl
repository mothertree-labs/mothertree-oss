<#--
    Platform WebAuthn Passwordless Registration Page
    This page is shown when users need to register a passkey.
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
            .webauthn-register-container {
                padding: 0 2rem 2.5rem;
                text-align: center;
            }
            
            .user-email-display {
                background: #f5f0e8;
                border-radius: 8px;
                padding: 1rem;
                margin-bottom: 1.5rem;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            .user-email-label {
                font-size: 0.85rem;
                color: #6b6b6b;
                margin-bottom: 0.25rem;
            }
            
            .user-email-value {
                font-size: 1.1rem;
                color: #3d3d3d;
                font-weight: 500;
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
            
            /* Register button */
            #registerWebAuthn, .webauthn-register-btn {
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
            
            #registerWebAuthn:hover, .webauthn-register-btn:hover {
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
            
            /* Hide default form elements that we don't need */
            .pf-c-form__label, .pf-c-form__helper-text {
                display: none !important;
            }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Set up your passkey</p>
        </div>
    <#elseif section = "form">
        <div class="webauthn-register-container">
            <#if user?? && user.username??>
                <div class="user-email-display">
                    <div class="user-email-label">Your email address</div>
                    <div class="user-email-value">${user.username}</div>
                </div>
            </#if>
            
            <div class="passkey-icon">🔐</div>
            
            <div class="passkey-instructions">
                A passkey lets you sign in securely using your device's biometrics (fingerprint or face) 
                or a security key. No password needed!
            </div>
            
            <form id="webauthn-register-form" action="${url.loginAction}" method="post">
                <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
                <input type="hidden" id="attestationObject" name="attestationObject"/>
                <input type="hidden" id="publicKeyCredentialId" name="publicKeyCredentialId"/>
                <input type="hidden" id="authenticatorLabel" name="authenticatorLabel"/>
                <input type="hidden" id="transports" name="transports"/>
                <input type="hidden" id="error" name="error"/>
                
                <button type="button" id="registerWebAuthn" class="webauthn-register-btn">
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z" fill="currentColor"/>
                    </svg>
                    Register Passkey
                </button>
            </form>
        </div>
        
        <script type="text/javascript">
            // WebAuthn registration challenge from Keycloak
            var challenge = "${challenge}";
            var userid = "${userid}";
            var username = "${username}";
            var signatureAlgorithms = [<#list signatureAlgorithms as sigAlg>${sigAlg}<#sep>, </#sep></#list>];
            var rpEntityName = "${rpEntityName}";
            var rpId = "${rpId}";
            var attestationConveyancePreference = "${attestationConveyancePreference}";
            var authenticatorAttachment = "${authenticatorAttachment}";
            var requireResidentKey = "${requireResidentKey}";
            var userVerificationRequirement = "${userVerificationRequirement}";
            var createTimeout = ${createTimeout};
            var excludeCredentialIds = "${excludeCredentialIds}";
            
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
            
            function registerSecurityKey() {
                var pubKeyCredParams = [];
                for (var i = 0; i < signatureAlgorithms.length; i++) {
                    pubKeyCredParams.push({
                        type: 'public-key',
                        alg: signatureAlgorithms[i]
                    });
                }
                
                var publicKeyCredentialCreationOptions = {
                    challenge: base64UrlToArrayBuffer(challenge),
                    rp: {
                        name: rpEntityName
                    },
                    user: {
                        id: base64UrlToArrayBuffer(userid),
                        name: username,
                        displayName: username
                    },
                    pubKeyCredParams: pubKeyCredParams,
                    authenticatorSelection: {
                        userVerification: userVerificationRequirement
                    },
                    timeout: createTimeout === 0 ? 60000 : createTimeout
                };
                
                if (rpId) {
                    publicKeyCredentialCreationOptions.rp.id = rpId;
                }
                
                if (attestationConveyancePreference !== 'not specified') {
                    publicKeyCredentialCreationOptions.attestation = attestationConveyancePreference;
                }
                
                if (authenticatorAttachment !== 'not specified') {
                    publicKeyCredentialCreationOptions.authenticatorSelection.authenticatorAttachment = authenticatorAttachment;
                }
                
                if (requireResidentKey === 'Yes') {
                    publicKeyCredentialCreationOptions.authenticatorSelection.requireResidentKey = true;
                    publicKeyCredentialCreationOptions.authenticatorSelection.residentKey = 'required';
                } else if (requireResidentKey === 'No') {
                    publicKeyCredentialCreationOptions.authenticatorSelection.requireResidentKey = false;
                    publicKeyCredentialCreationOptions.authenticatorSelection.residentKey = 'discouraged';
                }
                
                if (excludeCredentialIds) {
                    var excludeIds = excludeCredentialIds.split(',');
                    var excludeCredentials = [];
                    for (var i = 0; i < excludeIds.length; i++) {
                        if (excludeIds[i].trim()) {
                            excludeCredentials.push({
                                type: 'public-key',
                                id: base64UrlToArrayBuffer(excludeIds[i].trim())
                            });
                        }
                    }
                    if (excludeCredentials.length > 0) {
                        publicKeyCredentialCreationOptions.excludeCredentials = excludeCredentials;
                    }
                }
                
                navigator.credentials.create({publicKey: publicKeyCredentialCreationOptions})
                    .then(function(credential) {
                        var response = credential.response;
                        
                        document.getElementById('clientDataJSON').value = arrayBufferToBase64Url(response.clientDataJSON);
                        document.getElementById('attestationObject').value = arrayBufferToBase64Url(response.attestationObject);
                        document.getElementById('publicKeyCredentialId').value = arrayBufferToBase64Url(credential.rawId);
                        document.getElementById('authenticatorLabel').value = 'Passkey';
                        
                        var transports = [];
                        if (typeof response.getTransports === 'function') {
                            transports = response.getTransports();
                        }
                        document.getElementById('transports').value = transports.join(',');
                        
                        document.getElementById('webauthn-register-form').submit();
                    })
                    .catch(function(err) {
                        console.error('WebAuthn registration error:', err);
                        document.getElementById('error').value = err.message || 'Registration failed';
                        document.getElementById('webauthn-register-form').submit();
                    });
            }
            
            document.getElementById('registerWebAuthn').addEventListener('click', registerSecurityKey);
        </script>
    </#if>
</@layout.registrationLayout>
