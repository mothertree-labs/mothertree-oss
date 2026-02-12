<#-- 
    Custom platform login theme - extends base Keycloak theme
    This theme:
    - Changes branding from "LASUITE DOCS" to platform name
    - Supports passkey (WebAuthn) authentication
    - Shows Google OIDC identity provider button as fallback
    - Supports temporary password login for admin bootstrap
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('username','password') displayRequiredFields=false; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <#-- Inline critical CSS to bypass aggressive browser caching -->
        <style>
            /* Override Keycloak background - matching platform cream */
            html.login-pf, html.login-pf body, body, .login-pf-page {
                background: #f2efe8 !important;
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
                font-family: 'Tomorrow', sans-serif;
                font-size: 2.5rem; font-weight: 400; color: #4a6741; 
                margin: 0 0 0.5rem 0; letter-spacing: 0.03em;
            }
            .platform-welcome { 
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400; 
            }
            
            /* Login options container */
            .login-options {
                padding: 0 2rem 2.5rem;
            }
            
            /* Passkey login button */
            .passkey-login-btn {
                display: flex !important;
                align-items: center;
                justify-content: center;
                gap: 0.75rem;
                width: 100%;
                max-width: 320px;
                margin: 0 auto 1.5rem;
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
            }
            .passkey-login-btn:hover {
                background: #3d5636 !important;
                transform: translateY(-2px);
                box-shadow: 0 6px 16px rgba(74, 103, 65, 0.4) !important;
            }
            
            /* Divider */
            .login-divider {
                display: flex;
                align-items: center;
                margin: 1.5rem 0;
                color: #6b6b6b;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
            }
            .login-divider::before,
            .login-divider::after {
                content: '';
                flex: 1;
                border-bottom: 1px solid #ddd;
            }
            .login-divider span {
                padding: 0 1rem;
            }
            
            #kc-social-providers { 
                display: block !important; 
                padding: 0 !important;
                background: transparent !important;
                margin-top: 0 !important;
            }
            #kc-social-providers ul { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; align-items: center; gap: 1rem; }
            #kc-social-providers li { width: 100%; max-width: 320px; }
            #kc-social-providers a, .kc-social-provider-link {
                display: flex !important; align-items: center; justify-content: center; gap: 0.75rem;
                padding: 1rem 2rem !important; background: #fff !important;
                border: 2px solid #4a6741 !important; border-radius: 8px !important;
                color: #4a6741 !important; font-size: 1.1rem !important; font-weight: 500 !important;
                text-decoration: none !important; transition: all 0.2s ease !important;
                box-shadow: 0 2px 8px rgba(74, 103, 65, 0.15) !important;
            }
            #kc-social-providers a:hover { 
                background: #4a6741 !important; 
                color: #fff !important;
                transform: translateY(-2px); 
                box-shadow: 0 4px 12px rgba(74, 103, 65, 0.3) !important; 
            }
            
            /* Admin login toggle */
            .admin-login-toggle {
                text-align: center;
                margin-top: 1.5rem;
                padding-top: 1rem;
                border-top: 1px solid #eee;
            }
            .admin-login-toggle a {
                color: #6b6b6b;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                text-decoration: none;
            }
            .admin-login-toggle a:hover {
                color: #4a6741;
                text-decoration: underline;
            }
            
            /* Admin login form (hidden by default) */
            .admin-login-form {
                display: none;
                margin-top: 1.5rem;
                padding-top: 1rem;
                border-top: 1px solid #eee;
            }
            .admin-login-form.visible {
                display: block !important;
            }
            .admin-login-form .form-group {
                margin-bottom: 1rem;
            }
            .admin-login-form label {
                display: block !important;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                color: #6b6b6b;
                margin-bottom: 0.5rem;
            }
            .admin-login-form input[type="text"],
            .admin-login-form input[type="password"],
            .admin-login-form input#username,
            .admin-login-form input#password {
                display: block !important;
                width: 100%;
                padding: 0.75rem 1rem;
                border: 1px solid #ddd;
                border-radius: 8px;
                font-size: 1rem;
                font-family: 'Instrument Sans', sans-serif;
            }
            .admin-login-form input[type="text"]:focus,
            .admin-login-form input[type="password"]:focus {
                outline: none;
                border-color: #4a6741;
                box-shadow: 0 0 0 3px rgba(74, 103, 65, 0.1);
            }
            .admin-login-form button[type="submit"] {
                width: 100%;
                padding: 0.75rem 1rem;
                background: #4a6741;
                border: none;
                border-radius: 8px;
                color: #fff;
                font-size: 1rem;
                font-weight: 500;
                cursor: pointer;
                transition: all 0.2s ease;
            }
            .admin-login-form button[type="submit"]:hover {
                background: #3d5636;
            }
            
            /* Style logout and other form buttons */
            #kc-form-buttons input[type="submit"],
            .pf-c-button {
                display: inline-block !important;
                padding: 0.75rem 2rem !important;
                background: #4a6741 !important;
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
                background: #3d5636 !important;
            }
            hr, .kc-divider-text { display: none !important; }
            .pf-c-login__footer, .login-pf-page-footer { background: transparent !important; }
            
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
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.95rem;
                color: #6b6b6b;
                cursor: pointer;
            }
            .remember-me-label input[type="checkbox"] {
                width: 18px;
                height: 18px;
                accent-color: #4a6741;
                cursor: pointer;
            }
            .remember-me-label span {
                user-select: none;
            }
            
            /* Forgot password link */
            .forgot-password {
                text-align: center;
                margin-top: 1rem;
            }
            .forgot-password a {
                color: #6b6b6b;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 0.9rem;
                text-decoration: none;
            }
            .forgot-password a:hover {
                color: #4a6741;
                text-decoration: underline;
            }
            
            /* Hide default form elements */
            form#kc-form-login:not(.admin-login-form),
            #kc-form:not(.login-options) #kc-form-login {
                display: none !important;
            }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
            <p class="platform-welcome">Please login to continue</p>
        </div>
    <#elseif section = "form">
        <div class="login-options">
            <#-- Passkey Login Button -->
            <button type="button" id="passkey-login-btn" class="passkey-login-btn">
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z" fill="currentColor"/>
                </svg>
                Sign in with Passkey
            </button>
            
            <#-- Google/Social login -->
            <#if social.providers??>
                <div class="login-divider"><span>or</span></div>
                <div id="kc-social-providers" class="${properties.kcFormSocialAccountSectionClass!}">
                    <ul class="${properties.kcFormSocialAccountListClass!} <#if social.providers?size gt 3>${properties.kcFormSocialAccountListGridClass!}</#if>">
                        <#list social.providers as p>
                            <li>
                                <a id="social-${p.alias}" class="${properties.kcFormSocialAccountListButtonClass!} <#if social.providers?size gt 3>${properties.kcFormSocialAccountListButtonGridClass!}</#if>"
                                        type="button" href="${p.loginUrl}" data-base-url="${p.loginUrl}">
                                    <#if p.iconClasses?has_content>
                                        <i class="${properties.kcCommonLogoIdP!} ${p.iconClasses!}" aria-hidden="true"></i>
                                        <span class="${properties.kcFormSocialAccountNameClass!} kc-social-icon-text">${p.displayName!}</span>
                                    <#else>
                                        <span class="${properties.kcFormSocialAccountNameClass!}">${p.displayName!}</span>
                                    </#if>
                                </a>
                            </li>
                        </#list>
                    </ul>
                </div>
            </#if>
            
            <#-- Admin login toggle (for bootstrap with temp password) -->
            <div class="admin-login-toggle">
                <a href="#" id="show-admin-login">Admin login with password</a>
            </div>
            
            <#-- Admin login form (hidden by default) -->
            <form id="admin-login-form" class="admin-login-form" action="${url.loginAction}" method="post">
                <div class="form-group">
                    <label for="username">Email</label>
                    <input tabindex="1" id="username" name="username" value="${(login.username!'')}" type="text" autofocus autocomplete="username" />
                </div>
                <div class="form-group">
                    <label for="password">Password</label>
                    <input tabindex="2" id="password" name="password" type="password" autocomplete="current-password" />
                </div>
                <input type="hidden" id="id-hidden-input" name="credentialId" <#if auth.selectedCredential?has_content>value="${auth.selectedCredential}"</#if>/>
                <button type="submit" tabindex="3">Sign in</button>
            </form>
            
            <#-- Remember Me checkbox -->
            <#if realm.rememberMe>
                <div class="remember-me-container">
                    <label class="remember-me-label">
                        <input type="checkbox" id="rememberMe" name="rememberMe" form="admin-login-form" <#if login.rememberMe??>checked</#if>>
                        <span>${msg("rememberMe")}</span>
                    </label>
                </div>
            </#if>
            
            <#-- Forgot password / Account recovery link -->
            <#-- Link to admin portal's custom recovery flow instead of Keycloak's built-in reset -->
            <div class="forgot-password">
                <a href="#" id="recover-link">Lost your passkey?</a>
            </div>

            <#-- Guest registration link -->
            <div class="guest-register" style="text-align: center; margin-top: 0.75rem;">
                <a href="#" id="guest-register-link" style="color: #4a6741; font-family: 'Instrument Sans', sans-serif; font-size: 0.9rem; text-decoration: none;">Guest? Register here</a>
            </div>
        </div>
        
        <script type="text/javascript">
            // Toggle admin login form visibility
            var showAdminLogin = document.getElementById('show-admin-login');
            if (showAdminLogin) {
                showAdminLogin.addEventListener('click', function(e) {
                    e.preventDefault();
                    var form = document.getElementById('admin-login-form');
                    var passwordGroup = document.querySelector('.admin-login-form .form-group:nth-child(2)');
                    form.classList.toggle('visible');
                    // Show password field for admin login
                    if (passwordGroup) passwordGroup.style.display = 'block';
                    this.textContent = form.classList.contains('visible') ? 'Hide admin login' : 'Admin login with password';
                });
            }
            
            // Passkey login - show email-only form, Keycloak handles WebAuthn after username submission
            var passkeyBtn = document.getElementById('passkey-login-btn');
            if (passkeyBtn) {
                passkeyBtn.addEventListener('click', function() {
                    var form = document.getElementById('admin-login-form');
                    var toggle = document.getElementById('show-admin-login');
                    var passwordGroup = document.querySelector('.admin-login-form .form-group:nth-child(2)');
                    var usernameField = document.getElementById('username');
                    
                    // Show form
                    form.classList.add('visible');
                    if (toggle) toggle.textContent = 'Hide login form';
                    
                    // Hide password field - passkey flow doesn't need it
                    if (passwordGroup) passwordGroup.style.display = 'none';
                    
                    // Update placeholder and focus
                    if (usernameField) {
                        usernameField.placeholder = 'Enter your email';
                        usernameField.focus();
                    }
                    
                    // Change button text to indicate passkey flow
                    var submitBtn = form.querySelector('button[type="submit"]');
                    if (submitBtn) submitBtn.textContent = 'Continue with Passkey';
                });
            }
            
            // Update IdP links to include rememberMe parameter when checkbox is checked
            document.addEventListener('DOMContentLoaded', function() {
                var checkbox = document.getElementById('rememberMe');
                var idpLinks = document.querySelectorAll('#kc-social-providers a[data-base-url]');
                
                if (checkbox && idpLinks.length > 0) {
                    function updateLinks() {
                        idpLinks.forEach(function(link) {
                            var baseUrl = link.getAttribute('data-base-url');
                            if (checkbox.checked) {
                                var separator = baseUrl.indexOf('?') >= 0 ? '&' : '?';
                                link.href = baseUrl + separator + 'rememberMe=on';
                            } else {
                                link.href = baseUrl;
                            }
                        });
                    }
                    
                    checkbox.addEventListener('change', updateLinks);
                    updateLinks(); // Initialize on page load
                }
                
                // Set up recovery link - points to admin portal's /recover page
                var recoverLink = document.getElementById('recover-link');
                if (recoverLink) {
                    // Construct admin portal URL from current auth domain
                    // auth.dev.platform -> admin.dev.platform
                    // auth.platform -> admin.platform
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
            });
        </script>
    </#if>
</@layout.registrationLayout>
