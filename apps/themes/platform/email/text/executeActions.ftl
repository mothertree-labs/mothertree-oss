<#-- Safe attribute access: handles both string (multivalued=false) and list (multivalued=true) -->
<#function attrVal attr>
    <#if attr?is_sequence>
        <#return attr?first!"">
    <#else>
        <#return attr>
    </#if>
</#function>
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
<#if user.attributes?? && user.attributes.isRecoveryFlow?? && attrVal(user.attributes.isRecoveryFlow) == "true">
    <#assign isRecoveryFlow = true>
</#if>
<#-- Check if user has tenantEmail attribute AND is in swapped state (needs email swap before Keycloak action) -->
<#if user.attributes?? && user.attributes.tenantEmail?? && attrVal(user.attributes.tenantEmail) != "" && user.email != attrVal(user.attributes.tenantEmail)>
    <#assign needsEmailSwap = true>
    <#assign linkDomain = link?keep_after("://")?keep_before("/")>
    <#assign adminDomain = linkDomain?replace("auth.", "account.")>
    <#assign beginSetupToken = "">
    <#if user.attributes.beginSetupToken??>
        <#assign beginSetupToken = attrVal(user.attributes.beginSetupToken)>
    </#if>
    <#assign userId = "">
    <#if user.attributes.setupUserId??>
        <#assign userId = attrVal(user.attributes.setupUserId)>
    </#if>
    <#assign setupLink = "https://" + adminDomain + "/beginSetup?userId=" + userId + "&token=" + beginSetupToken?url('UTF-8') + "&next=" + link?url('UTF-8')>
<#else>
    <#assign setupLink = link>
</#if>
<#if isRecoveryFlow>
${realmName} - Account Recovery

Hello ${user.firstName!"there"},

You requested to recover access to your ${realmName} account. This email was sent to your recovery email address because you indicated you've lost your passkey.

<#if user.attributes?? && user.attributes.tenantEmail?? && attrVal(user.attributes.tenantEmail) != "">
Account being recovered: ${attrVal(user.attributes.tenantEmail)}
</#if>

WHAT HAPPENS NEXT:
Click the link below to register a new passkey for your account. Your old passkey has been removed for security.

${setupLink}

This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, you can request a new recovery link from the login page.

SECURITY NOTICE: If you didn't request this account recovery, please contact support immediately as someone may be trying to access your account.

Need help? Contact your administrator
<#if properties.privacyPolicyUrl?has_content || properties.termsOfUseUrl?has_content || properties.acceptableUsePolicyUrl?has_content>

<#if properties.privacyPolicyUrl?has_content>Privacy Policy: ${properties.privacyPolicyUrl}</#if>
<#if properties.termsOfUseUrl?has_content>Terms of Use: ${properties.termsOfUseUrl}</#if>
<#if properties.acceptableUsePolicyUrl?has_content>Acceptable Use Policy: ${properties.acceptableUsePolicyUrl}</#if>
</#if>
<#elseif isPasswordReset>
${realmName} - Password Reset

Hello ${user.firstName!"there"},

We received a request to reset your password and recover access to your ${realmName} account. This email was sent to your recovery email address.

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
<#if properties.privacyPolicyUrl?has_content || properties.termsOfUseUrl?has_content || properties.acceptableUsePolicyUrl?has_content>

<#if properties.privacyPolicyUrl?has_content>Privacy Policy: ${properties.privacyPolicyUrl}</#if>
<#if properties.termsOfUseUrl?has_content>Terms of Use: ${properties.termsOfUseUrl}</#if>
<#if properties.acceptableUsePolicyUrl?has_content>Acceptable Use Policy: ${properties.acceptableUsePolicyUrl}</#if>
</#if>
<#else>
Welcome to ${realmName}!

Hello ${user.firstName!"there"},

You've been invited to join ${realmName}. To complete your account setup, you'll need to register a passkey - a secure way to sign in using your device's biometrics or a security key.

<#if user.attributes?? && user.attributes.tenantEmail?? && attrVal(user.attributes.tenantEmail) != "">
Your ${realmName} email will be: ${attrVal(user.attributes.tenantEmail)}
</#if>

Click the link below to set up your passkey:

${setupLink}

This link will expire in ${linkExpirationFormatter(linkExpiration)}. If it expires, please contact your administrator for a new invitation.

If you didn't expect this email, you can safely ignore it.

Need help? Contact your administrator
<#if properties.privacyPolicyUrl?has_content || properties.termsOfUseUrl?has_content || properties.acceptableUsePolicyUrl?has_content>

<#if properties.privacyPolicyUrl?has_content>Privacy Policy: ${properties.privacyPolicyUrl}</#if>
<#if properties.termsOfUseUrl?has_content>Terms of Use: ${properties.termsOfUseUrl}</#if>
<#if properties.acceptableUsePolicyUrl?has_content>Acceptable Use Policy: ${properties.acceptableUsePolicyUrl}</#if>
</#if>
</#if>
