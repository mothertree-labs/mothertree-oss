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
<#if isRecoveryFlow>
${realmDisplayName!"the platform"} - Account Recovery

Hello ${user.firstName!"there"},

You requested to recover access to your ${realmDisplayName!"the platform"} account. This email was sent to your recovery email address because you indicated you've lost your passkey.

<#if user.attributes?? && user.attributes.tenantEmail?? && user.attributes.tenantEmail?first??>
Account being recovered: ${user.attributes.tenantEmail?first}
</#if>

WHAT HAPPENS NEXT:
Click the link below to register a new passkey for your account. Your old passkey has been removed for security.

${setupLink}

This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, you can request a new recovery link from the login page.

SECURITY NOTICE: If you didn't request this account recovery, please contact support immediately as someone may be trying to access your account.

Need help? Contact your administrator
<#elseif isPasswordReset>
${realmDisplayName!"the platform"} - Password Reset

Hello ${user.firstName!"there"},

We received a request to reset your password and recover access to your ${realmDisplayName!"the platform"} account. This email was sent to your recovery email address.

<#if user.email??>
Recovery email address: ${user.email}
</#if>

Click the link below to set a new password:

${setupLink}

<#if isPasskeySetup>
NEXT STEP: After resetting your password, you'll be prompted to register a new passkey for secure, passwordless login.
</#if>

This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, you can request a new reset link from the login page.

If you didn't request this password reset, you can safely ignore this email. Your password will remain unchanged.

Need help? Contact your administrator
<#else>
Welcome to ${realmDisplayName!"the platform"}!

Hello ${user.firstName!"there"},

You've been invited to join ${realmDisplayName!"the platform"}. To complete your account setup, you'll need to register a passkey - a secure way to sign in using your device's biometrics or a security key.

<#if user.attributes?? && user.attributes.tenantEmail?? && user.attributes.tenantEmail?first??>
Your ${realmDisplayName!"the platform"} email will be: ${user.attributes.tenantEmail?first}
</#if>

Click the link below to set up your passkey:

${setupLink}

This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, please contact your administrator for a new invitation.

If you didn't expect this email, you can safely ignore it.

Need help? Contact your administrator
</#if>
