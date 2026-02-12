<#--
    Platform Info/Required Actions Page
    This page is shown when the user needs to perform required actions (like passkey registration)
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
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
                margin-bottom: 2rem;
                padding-top: 3rem;
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
            
            .info-card {
                background: white;
                border-radius: 12px;
                padding: 2rem;
                max-width: 450px;
                margin: 0 auto;
                box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            }
            
            .info-icon {
                width: 64px;
                height: 64px;
                margin: 0 auto 1.5rem;
                background: #EDF3EB;
                border-radius: 50%;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            
            .info-icon svg {
                width: 32px;
                height: 32px;
                fill: var(--sage);
            }
            
            .info-title {
                font-size: 1.5rem;
                font-weight: 500;
                color: var(--sage);
                text-align: center;
                margin: 0 0 1rem 0;
            }
            
            .info-message {
                color: var(--warm-gray);
                text-align: center;
                margin-bottom: 1.5rem;
                line-height: 1.6;
            }
            
            .action-list {
                background: #f8f9fa;
                border-radius: 8px;
                padding: 1rem 1.5rem;
                margin-bottom: 1.5rem;
            }
            
            .action-item {
                display: flex;
                align-items: center;
                gap: 0.75rem;
                color: #333;
                padding: 0.5rem 0;
            }
            
            .action-item svg {
                width: 20px;
                height: 20px;
                fill: var(--sage);
                flex-shrink: 0;
            }
            
            .proceed-link {
                display: block;
                width: 100%;
                padding: 1rem 2rem;
                background: var(--sage);
                color: white;
                text-decoration: none;
                border-radius: 8px;
                font-size: 1rem;
                font-weight: 500;
                text-align: center;
                transition: background-color 0.2s;
                box-sizing: border-box;
            }
            
            .proceed-link:hover {
                background: var(--sage-dark);
            }
            
            .back-link {
                text-align: center;
                margin-top: 1rem;
            }
            
            .back-link a {
                color: var(--warm-gray);
                text-decoration: none;
                font-size: 0.9rem;
            }
            
            .back-link a:hover {
                color: var(--sage);
            }
            
            /* Hide default Keycloak elements */
            #kc-info, #kc-info-wrapper {
                display: none !important;
            }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Complete your account setup</p>
        </div>
    <#elseif section = "form">
        <div class="info-card">
            <div class="info-icon">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/>
                </svg>
            </div>
            
            <h2 class="info-title">Set Up Your Passkey</h2>
            
            <p class="info-message">
                To secure your account, you'll need to register a passkey. 
                This can be your device's fingerprint, face recognition, or a security key.
            </p>
            
            <div class="action-list">
                <#if requiredActions??>
                    <#list requiredActions as reqAction>
                        <div class="action-item">
                            <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                                <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>
                            </svg>
                            <span>
                                <#if reqAction == "webauthn-register-passwordless">
                                    Register a passwordless passkey
                                <#elseif reqAction == "webauthn-register">
                                    Register a security key
                                <#elseif reqAction == "CONFIGURE_TOTP">
                                    Set up two-factor authentication
                                <#elseif reqAction == "UPDATE_PASSWORD">
                                    Update your password
                                <#elseif reqAction == "UPDATE_PROFILE">
                                    Complete your profile
                                <#elseif reqAction == "VERIFY_EMAIL">
                                    Verify your email address
                                <#else>
                                    ${msg("requiredAction.${reqAction}")}
                                </#if>
                            </span>
                        </div>
                    </#list>
                <#else>
                    <div class="action-item">
                        <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z"/>
                        </svg>
                        <span>${message.summary!""}</span>
                    </div>
                </#if>
            </div>
            
            <#if pageRedirectUri?has_content>
                <a href="${pageRedirectUri}" class="proceed-link">Continue</a>
            <#elseif actionUri?has_content>
                <a href="${actionUri}" class="proceed-link">Click here to proceed</a>
            <#elseif (client.baseUrl)?has_content>
                <a href="${client.baseUrl}" class="proceed-link">Back to Application</a>
            </#if>
            
            <#if skipLink??>
                <div class="back-link">
                    <a href="${skipLink}">Skip for now</a>
                </div>
            </#if>
        </div>
    </#if>
</@layout.registrationLayout>
