<#--
    Platform Update Password Page
    This page is shown when the user needs to set a new password (e.g., after password reset)
    After password update, user will be prompted to register a passkey
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('password','password-confirm'); section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <style>
            /* Colors matching platform theme */
            :root {
                --sage: #4a6741;
                --sage-dark: #3d5636;
                --cream: #f2efe8;
                --warm-gray: #6b6b6b;
            }
            
            html.login-pf, html.login-pf body, body, .login-pf-page {
                background: var(--cream) !important;
                background-image: none !important;
                min-height: 100vh !important;
            }
            
            .login-pf-page-header { display: none !important; }
            
            .login-pf-page {
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                justify-content: center !important;
                padding: 2rem !important;
            }
            
            .platform-header {
                text-align: center;
                padding: 2.5rem 2rem 1.5rem;
            }
            
            .platform-title {
                font-family: 'Tomorrow', sans-serif;
                font-size: 2.5rem;
                font-weight: 400;
                color: var(--sage);
                margin: 0 0 0.5rem 0;
                letter-spacing: 0.03em;
            }
            
            .platform-welcome {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem;
                color: var(--warm-gray);
                margin: 0;
                font-weight: 400;
            }
            
            .update-card {
                background: rgba(255,255,255,0.9);
                border-radius: 16px;
                box-shadow: 0 4px 24px rgba(0,0,0,0.08);
                padding: 2rem;
                max-width: 420px;
                width: 100%;
                margin: 0 auto;
            }
            
            .update-icon {
                width: 64px;
                height: 64px;
                margin: 0 auto 1.5rem;
                background: #EDF3EB;
                border-radius: 50%;
                display: flex;
                align-items: center;
                justify-content: center;
            }
            
            .update-icon svg {
                width: 32px;
                height: 32px;
                fill: var(--sage);
            }
            
            .update-title {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.5rem;
                font-weight: 500;
                color: var(--sage);
                text-align: center;
                margin: 0 0 1rem 0;
            }
            
            .update-message {
                font-family: 'Instrument Sans', sans-serif;
                color: var(--warm-gray);
                text-align: center;
                margin-bottom: 1.5rem;
                line-height: 1.6;
                font-size: 0.95rem;
            }
            
            .info-note {
                background: #EDF3EB;
                border-radius: 8px;
                padding: 1rem;
                margin-bottom: 1.5rem;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                color: var(--sage-dark);
                text-align: center;
            }
            
            .info-note strong {
                display: block;
                margin-bottom: 0.25rem;
            }
            
            .form-group {
                margin-bottom: 1.5rem;
            }
            
            .form-group label {
                display: block;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                color: var(--warm-gray);
                margin-bottom: 0.5rem;
            }
            
            .form-group input {
                width: 100%;
                padding: 0.75rem 1rem;
                border: 1px solid #ddd;
                border-radius: 8px;
                font-size: 1rem;
                font-family: 'Instrument Sans', sans-serif;
                box-sizing: border-box;
            }
            
            .form-group input:focus {
                outline: none;
                border-color: var(--sage);
                box-shadow: 0 0 0 3px rgba(74, 103, 65, 0.1);
            }
            
            .form-group input.error {
                border-color: #dc3545;
            }
            
            .error-message {
                color: #dc3545;
                font-size: 0.85rem;
                margin-top: 0.5rem;
                font-family: 'Instrument Sans', sans-serif;
            }
            
            .submit-btn {
                display: block;
                width: 100%;
                padding: 1rem 2rem;
                background: var(--sage);
                border: none;
                border-radius: 8px;
                color: white;
                font-size: 1rem;
                font-weight: 500;
                font-family: 'Instrument Sans', sans-serif;
                cursor: pointer;
                transition: all 0.2s ease;
                box-shadow: 0 4px 12px rgba(74, 103, 65, 0.3);
            }
            
            .submit-btn:hover {
                background: var(--sage-dark);
                transform: translateY(-2px);
                box-shadow: 0 6px 16px rgba(74, 103, 65, 0.4);
            }
            
            .logout-link {
                text-align: center;
                margin-top: 1.5rem;
            }
            
            .logout-link a {
                color: var(--warm-gray);
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                text-decoration: none;
            }
            
            .logout-link a:hover {
                color: var(--sage);
                text-decoration: underline;
            }
            
            /* Hide default Keycloak elements */
            .card-pf { background: transparent !important; box-shadow: none !important; border: none !important; }
            #kc-info, #kc-info-wrapper { display: none !important; }
            .pf-c-login__footer, .login-pf-page-footer { background: transparent !important; }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Set a temporary password</p>
        </div>
    <#elseif section = "form">
        <div class="update-card">
            <div class="update-icon">
                <svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/>
                </svg>
            </div>
            
            <h2 class="update-title">Update Your Password</h2>
            
            <p class="update-message">
                Please set a new password for your account.
            </p>
            
            <div class="info-note">
                <strong>Next step: Register your passkey</strong>
                After setting your password, you'll be prompted to register a new passkey for secure, passwordless login.
            </div>
            
            <form id="kc-passwd-update-form" action="${url.loginAction}" method="post">
                <input type="text" id="username" name="username" value="${username}" autocomplete="username" readonly="readonly" style="display:none;"/>
                
                <div class="form-group">
                    <label for="password-new">${msg("passwordNew")}</label>
                    <input type="password" id="password-new" name="password-new" class="${(messagesPerField.existsError('password','password-confirm'))?then('error', '')}" autofocus autocomplete="new-password" aria-invalid="<#if messagesPerField.existsError('password','password-confirm')>true</#if>"/>
                    <#if messagesPerField.existsError('password')>
                        <span class="error-message" aria-live="polite">
                            ${kcSanitize(messagesPerField.get('password'))?no_esc}
                        </span>
                    </#if>
                </div>
                
                <div class="form-group">
                    <label for="password-confirm">${msg("passwordConfirm")}</label>
                    <input type="password" id="password-confirm" name="password-confirm" class="${(messagesPerField.existsError('password-confirm'))?then('error', '')}" autocomplete="new-password" aria-invalid="<#if messagesPerField.existsError('password-confirm')>true</#if>"/>
                    <#if messagesPerField.existsError('password-confirm')>
                        <span class="error-message" aria-live="polite">
                            ${kcSanitize(messagesPerField.get('password-confirm'))?no_esc}
                        </span>
                    </#if>
                </div>
                
                <#if isAppInitiatedAction??>
                    <input type="hidden" id="logout-sessions" name="logout-sessions" value="on"/>
                </#if>
                
                <button type="submit" class="submit-btn">${msg("doSubmit")}</button>
            </form>
            
            <#if isAppInitiatedAction??>
                <div class="logout-link">
                    <a href="${url.loginUrl}">Cancel</a>
                </div>
            </#if>
        </div>
    </#if>
</@layout.registrationLayout>
