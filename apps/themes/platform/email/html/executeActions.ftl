<#outputformat "HTML">
<#-- Determine the type of email based on required actions and user attributes -->
<#assign isPasswordReset = false>
<#assign isPasskeySetup = false>
<#assign isRecoveryFlow = false>
<#assign needsEmailSwap = false>
<#if requiredActions??>
    <#list requiredActions as reqAction>
        <#if reqAction == "UPDATE_PASSWORD">
            <#assign isPasswordReset = true>
        </#if>
        <#if reqAction == "webauthn-register-passwordless" || reqAction == "WEBAUTHN_REGISTER_PASSWORDLESS">
            <#assign isPasskeySetup = true>
        </#if>
    </#list>
</#if>
<#-- Check if this is a recovery flow (set by admin portal during account recovery) -->
<#if user.attributes?? && user.attributes.isRecoveryFlow?? && user.attributes.isRecoveryFlow?first?? && user.attributes.isRecoveryFlow?first == "true">
    <#assign isRecoveryFlow = true>
</#if>
<#-- Check if user has tenantEmail attribute (needs email swap before Keycloak action) -->
<#if user.attributes?? && user.attributes.tenantEmail?? && user.attributes.tenantEmail?first?? && user.attributes.tenantEmail?first != "">
    <#assign needsEmailSwap = true>
    <#-- Route through account portal to swap email before Keycloak processes the action -->
    <#-- Transform auth.X.org to account.X.org to find the account portal -->
    <#assign linkDomain = link?keep_after("://")?keep_before("/")>
    <#assign adminDomain = linkDomain?replace("auth.", "account.")>
    <#assign beginSetupToken = "">
    <#if user.attributes.beginSetupToken?? && user.attributes.beginSetupToken?first??>
        <#assign beginSetupToken = user.attributes.beginSetupToken?first>
    </#if>
    <#assign setupLink = "https://" + adminDomain + "/beginSetup?userId=" + user.id + "&token=" + beginSetupToken?url + "&next=" + link?url>
<#else>
    <#assign setupLink = link>
</#if>
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><#if isRecoveryFlow>Recover Your ${realmDisplayName!"the platform"} Account<#elseif isPasswordReset>Reset Your Password<#else>Welcome to ${realmName}</#if></title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            color: #3d3d3d;
            background-color: #f2efe8;
            margin: 0;
            padding: 0;
        }
        .container {
            max-width: 600px;
            margin: 0 auto;
            padding: 40px 20px;
        }
        .card {
            background: #ffffff;
            border-radius: 16px;
            box-shadow: 0 4px 24px rgba(0,0,0,0.08);
            padding: 40px;
        }
        .logo {
            text-align: center;
            margin-bottom: 30px;
        }
        .logo h1 {
            color: #4a6741;
            font-size: 2rem;
            font-weight: 400;
            margin: 0;
            letter-spacing: 0.03em;
        }
        h2 {
            color: #4a6741;
            font-size: 1.5rem;
            font-weight: 500;
            margin-top: 0;
        }
        p {
            color: #6b6b6b;
            margin: 16px 0;
        }
        .email-display {
            background: #f5f0e8;
            border-radius: 8px;
            padding: 16px;
            margin: 24px 0;
            text-align: center;
        }
        .email-display .label {
            font-size: 0.85rem;
            color: #6b6b6b;
            margin-bottom: 4px;
        }
        .email-display .email {
            font-size: 1.2rem;
            color: #3d3d3d;
            font-weight: 500;
        }
        .button {
            display: inline-block;
            background: #4a6741;
            color: #ffffff !important;
            text-decoration: none;
            padding: 14px 32px;
            border-radius: 8px;
            font-size: 1.1rem;
            font-weight: 500;
            margin: 24px 0;
            box-shadow: 0 4px 12px rgba(74, 103, 65, 0.3);
        }
        .button:hover {
            background: #3d5636;
        }
        .button-container {
            text-align: center;
        }
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #eee;
            font-size: 0.85rem;
            color: #999;
            text-align: center;
        }
        .footer a {
            color: #4a6741;
            text-decoration: none;
        }
        .expiry-notice {
            background: #fff7ed;
            border: 1px solid #fed7aa;
            border-radius: 8px;
            padding: 12px;
            margin-top: 24px;
            font-size: 0.9rem;
            color: #9a3412;
        }
        .info-box {
            background: #EDF3EB;
            border-radius: 8px;
            padding: 16px;
            margin: 16px 0;
            font-size: 0.95rem;
            color: #3d5636;
        }
        .info-box strong {
            display: block;
            margin-bottom: 4px;
            color: #4a6741;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <div class="logo">
                <h1>${realmDisplayName!"the platform"}</h1>
            </div>
            
            <#if isRecoveryFlow>
                <#-- Account Recovery Flow - user lost their passkey -->
                <h2>Recover Your Account</h2>
                
                <p>Hello ${user.firstName!"there"},</p>
                
                <p>You requested to recover access to your ${realmDisplayName!"the platform"} account. This email was sent to your recovery email address because you indicated you've lost your passkey.</p>
                
                <#if user.attributes?? && user.attributes.tenantEmail?? && user.attributes.tenantEmail?first??>
                <div class="email-display">
                    <div class="label">Account being recovered</div>
                    <div class="email">${user.attributes.tenantEmail?first}</div>
                </div>
                </#if>
                
                <div class="info-box">
                    <strong>What happens next?</strong>
                    Click the button below to register a new passkey for your account. Your old passkey has been removed for security.
                </div>
                
                <div class="button-container">
                    <a href="${setupLink}" class="button">Register New Passkey</a>
                </div>
                
                <div class="expiry-notice">
                    This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, you can request a new recovery link from the login page.
                </div>
                
                <div class="footer">
                    <p>If you didn't request this account recovery, please contact support immediately as someone may be trying to access your account.</p>
                    <p>Need help? Contact your administrator</p>
                </div>
            <#elseif isPasswordReset>
                <h2>Reset Your Password</h2>
                
                <p>Hello ${user.firstName!"there"},</p>
                
                <p>We received a request to reset your password and recover access to your ${realmDisplayName!"the platform"} account. This email was sent to your recovery email address.</p>
                
                <#if user.email??>
                <div class="email-display">
                    <div class="label">Recovery email address</div>
                    <div class="email">${user.email}</div>
                </div>
                </#if>
                
                <p>Click the button below to set a new password:</p>
                
                <div class="button-container">
                    <a href="${setupLink}" class="button">Reset My Password</a>
                </div>
                
                <#if isPasskeySetup>
                <div class="info-box">
                    <strong>Re-register your passkey</strong>
                    After resetting your password, you'll be prompted to register a new passkey for secure, passwordless login.
                </div>
                </#if>
                
                <div class="expiry-notice">
                    This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, you can request a new reset link from the login page.
                </div>
                
                <div class="footer">
                    <p>If you didn't request this password reset, you can safely ignore this email. Your password will remain unchanged.</p>
                    <p>Need help? Contact your administrator</p>
                </div>
            <#else>
                <#-- New User Signup/Invitation -->
                <h2>Welcome! Set up your account</h2>
                
                <p>Hello ${user.firstName!"there"},</p>
                
                <p>You've been invited to join ${realmDisplayName!"the platform"}. To complete your account setup, you'll need to register a passkey - a secure way to sign in using your device's biometrics or a security key.</p>
                
                <#if user.attributes?? && user.attributes.tenantEmail?? && user.attributes.tenantEmail?first??>
                <div class="email-display">
                    <div class="label">Your ${realmDisplayName!"the platform"} email will be</div>
                    <div class="email">${user.attributes.tenantEmail?first}</div>
                </div>
                </#if>
                
                <p>Click the button below to set up your passkey:</p>
                
                <div class="button-container">
                    <a href="${setupLink}" class="button">Set Up My Passkey</a>
                </div>
                
                <div class="expiry-notice">
                    This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, please contact your administrator for a new invitation.
                </div>
                
                <div class="footer">
                    <p>If you didn't expect this email, you can safely ignore it.</p>
                    <p>Need help? Contact your administrator</p>
                </div>
            </#if>
        </div>
    </div>
</body>
</html>
</#outputformat>
