<#--
    Platform Select Authenticator Page
    This page is shown when users can choose between multiple authentication methods.
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
            
            /* Authenticator selector container */
            .authenticator-selector-container {
                padding: 0 2rem 2.5rem;
            }
            
            .authenticator-list {
                list-style: none;
                padding: 0;
                margin: 0;
                display: flex;
                flex-direction: column;
                gap: 1rem;
            }
            
            .authenticator-item {
                width: 100%;
            }
            
            .authenticator-link {
                display: flex !important;
                align-items: center;
                gap: 1rem;
                padding: 1rem 1.5rem !important;
                background: #fff !important;
                border: 2px solid #e5e5e5 !important;
                border-radius: 12px !important;
                color: #333 !important;
                text-decoration: none !important;
                transition: all 0.2s ease !important;
            }
            
            .authenticator-link:hover {
                border-color: #4a6741 !important;
                background: #f8fdf7 !important;
                transform: translateY(-2px);
                box-shadow: 0 4px 12px rgba(74, 103, 65, 0.15) !important;
            }
            
            .authenticator-icon {
                width: 48px;
                height: 48px;
                display: flex;
                align-items: center;
                justify-content: center;
                background: #f2efe8;
                border-radius: 8px;
                flex-shrink: 0;
            }
            
            .authenticator-icon svg {
                width: 28px;
                height: 28px;
                color: #4a6741;
            }
            
            .authenticator-info {
                flex: 1;
            }
            
            .authenticator-name {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem;
                font-weight: 500;
                color: #333;
                margin: 0 0 0.25rem 0;
            }
            
            .authenticator-description {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                color: #6b6b6b;
                margin: 0;
            }
            
            /* Back link */
            .back-link {
                text-align: center;
                margin-top: 1.5rem;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            .back-link a {
                color: #6b6b6b;
                text-decoration: none;
            }
            
            .back-link a:hover {
                color: #4a6741;
                text-decoration: underline;
            }
            
            /* Recovery link */
            .recover-passkey {
                margin-top: 1rem;
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
            <p class="platform-welcome">Choose how to sign in</p>
        </div>
    <#elseif section = "form">
        <div class="authenticator-selector-container">
            <ul class="authenticator-list">
                <#list auth.authenticationSelections as selection>
                    <li class="authenticator-item">
                        <a href="${selection.authExecId}" class="authenticator-link">
                            <div class="authenticator-icon">
                                <#if selection.displayName?contains("Passkey") || selection.displayName?contains("WebAuthn") || selection.displayName?contains("Security Key")>
                                    <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                                        <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                                    </svg>
                                <#elseif selection.displayName?contains("Password")>
                                    <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                                        <path d="M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z" fill="currentColor"/>
                                    </svg>
                                <#else>
                                    <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                                        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z" fill="currentColor"/>
                                    </svg>
                                </#if>
                            </div>
                            <div class="authenticator-info">
                                <p class="authenticator-name">
                                    <#if selection.displayName?contains("Passkey") || selection.displayName?contains("passwordless")>
                                        Sign in with Passkey
                                    <#elseif selection.displayName?contains("Password")>
                                        Sign in with Password
                                    <#else>
                                        ${selection.displayName}
                                    </#if>
                                </p>
                                <p class="authenticator-description">
                                    <#if selection.displayName?contains("Passkey") || selection.displayName?contains("passwordless")>
                                        Use your device's biometrics or security key
                                    <#elseif selection.displayName?contains("Password")>
                                        Enter your password to sign in
                                    <#else>
                                        ${selection.helpText!}
                                    </#if>
                                </p>
                            </div>
                        </a>
                    </li>
                </#list>
            </ul>
            
            <div class="back-link">
                <a href="${url.loginUrl}">Start over</a>
            </div>
            
            <div class="recover-passkey">
                <a href="#" id="recover-link">Lost your passkey?</a>
            </div>
        </div>
        
        <script type="text/javascript">
            // Set up recovery link - points to admin portal's /recover page
            var recoverLink = document.getElementById('recover-link');
            if (recoverLink) {
                var currentHost = window.location.hostname;
                var adminHost = currentHost.replace(/^auth\./, 'admin.');
                recoverLink.href = 'https://' + adminHost + '/recover';
            }
        </script>
    </#if>
</@layout.registrationLayout>
