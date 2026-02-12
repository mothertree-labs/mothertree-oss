<#--
    Platform Passwordless WebAuthn Registration Page
    This page is shown when user needs to register a passkey
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <style>
            /* Colors matching Admin Portal */
            :root {
                --sage: #7C9A6C;
                --sage-dark: #5A7A4C;
                --cream: #FAF8F5;
                --warm-gray: #6B6B6B;
            }
            
            body {
                background: var(--cream) !important;
                min-height: 100vh;
                margin: 0;
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            }
            
            #kc-header-wrapper {
                display: none;
            }
            
            .platform-header {
                text-align: center;
                padding: 3rem 0 1rem;
            }
            
            .platform-title {
                font-size: 2rem;
                color: var(--sage);
                margin: 0 0 0.5rem 0;
                font-weight: 400;
            }
            
            .platform-welcome {
                color: var(--warm-gray);
                font-size: 1rem;
                margin: 0;
            }
            
            .login-pf-page {
                display: flex;
                justify-content: center;
                align-items: flex-start;
                padding: 2rem;
                background: var(--cream) !important;
            }
            
            #kc-content {
                width: 100%;
                max-width: 500px;
            }
            
            #kc-content-wrapper {
                background: white;
                border-radius: 12px;
                padding: 2rem;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            }
            
            .passkey-card {
                text-align: center;
            }
            
            .passkey-icon {
                width: 64px;
                height: 64px;
                margin: 0 auto 1.5rem;
                background: #EDF3EB;
                border-radius: 50%;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            
            .passkey-icon svg {
                width: 32px;
                height: 32px;
                fill: var(--sage);
            }
            
            .passkey-title {
                font-size: 1.5rem;
                font-weight: 500;
                color: var(--sage);
                margin: 0 0 1rem 0;
            }
            
            .passkey-description {
                color: var(--warm-gray);
                margin-bottom: 2rem;
                line-height: 1.6;
            }
            
            /* Style the form */
            #kc-form {
                margin-top: 1.5rem;
            }
            
            .form-group {
                margin-bottom: 1.5rem;
            }
            
            .form-group label {
                display: block;
                margin-bottom: 0.5rem;
                color: var(--warm-gray);
                font-weight: 500;
            }
            
            .form-group input[type="text"] {
                width: 100%;
                padding: 0.75rem 1rem;
                border: 1px solid #d1d5db;
                border-radius: 8px;
                font-size: 1rem;
                transition: border-color 0.2s, box-shadow 0.2s;
                box-sizing: border-box;
            }
            
            .form-group input[type="text"]:focus {
                outline: none;
                border-color: var(--sage);
                box-shadow: 0 0 0 2px rgba(124, 154, 108, 0.2);
            }
            
            /* Register button */
            input[type="submit"], 
            button[type="submit"],
            .btn-primary {
                width: 100%;
                padding: 1rem 2rem;
                background: var(--sage);
                color: white;
                border: none;
                border-radius: 8px;
                font-size: 1rem;
                font-weight: 500;
                cursor: pointer;
                transition: background-color 0.2s;
            }
            
            input[type="submit"]:hover,
            button[type="submit"]:hover,
            .btn-primary:hover {
                background: var(--sage-dark);
            }
            
            /* Cancel/back link */
            #kc-form-options,
            .kc-form-options {
                text-align: center;
                margin-top: 1.5rem;
            }
            
            #kc-form-options a,
            .back-link a {
                color: var(--warm-gray);
                text-decoration: none;
                font-size: 0.9rem;
            }
            
            #kc-form-options a:hover,
            .back-link a:hover {
                color: var(--sage);
            }
            
            /* Hide default Keycloak elements we don't need */
            #kc-info, #kc-info-wrapper, .kc-social-providers {
                display: none !important;
            }
            
            /* Alert styling */
            .alert {
                padding: 1rem;
                border-radius: 8px;
                margin-bottom: 1.5rem;
            }
            
            .alert-error {
                background: #fef2f2;
                color: #dc2626;
                border: 1px solid #fecaca;
            }
            
            .alert-success {
                background: #f0fdf4;
                color: #16a34a;
                border: 1px solid #bbf7d0;
            }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Complete your account setup</p>
        </div>
    <#elseif section = "title">
        Set Up Your Passkey
    <#elseif section = "form">
        <div class="passkey-card">
            <div class="passkey-icon">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>
                </svg>
            </div>
            
            <h2 class="passkey-title">Set Up Your Passkey</h2>
            
            <p class="passkey-description">
                To secure your account, you'll need to register a passkey. 
                This can be your device's fingerprint, face recognition, or a security key.
            </p>
        </div>
        
        <form id="register" action="${url.loginAction}" method="post">
            <div class="form-group">
                <label for="registerWebAuthnLabel">${msg("webauthn-registration-label-label")}</label>
                <input type="text" id="registerWebAuthnLabel" name="registerWebAuthnLabel" 
                       value="${msg('webauthn-passwordless-registration-label-default')}"
                       placeholder="e.g., MacBook Touch ID" />
            </div>
            
            <input type="hidden" id="clientDataJSON" name="clientDataJSON"/>
            <input type="hidden" id="attestationObject" name="attestationObject"/>
            <input type="hidden" id="publicKeyCredentialId" name="publicKeyCredentialId"/>
            <input type="hidden" id="authenticatorLabel" name="authenticatorLabel"/>
            <input type="hidden" id="transports" name="transports"/>
            <input type="hidden" id="error" name="error"/>
        </form>
        
        <button type="button" class="btn-primary" id="registerBtn" onclick="registerWebAuthn()">
            Register Passkey
        </button>
        
        <#if !isSetRetry?has_content && isAppInitiatedAction?has_content>
            <div class="back-link">
                <form action="${url.loginAction}" method="post">
                    <input type="hidden" id="isSetRetry" name="isSetRetry" value="true"/>
                    <a href="javascript:void(0)" onclick="this.parentNode.submit()">Skip for now</a>
                </form>
            </div>
        </#if>
        
        <script type="text/javascript" src="${url.resourcesCommonPath}/node_modules/jquery/dist/jquery.min.js"></script>
        <script type="text/javascript">
            function registerWebAuthn() {
                // Get challenge and other params from Keycloak
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
    </#if>
</@layout.registrationLayout>
