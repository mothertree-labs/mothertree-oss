<#--
    Platform Password Authentication Page
    Rendered when a user authenticates with password in the credential subflow
    (dev environment only — prod uses passkey-only).
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=!messagesPerField.existsError('password') displayRequiredFields=false; section>
    <#if section = "header">
        ${realm.displayName!"the platform"}
    <#elseif section = "form">
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />

        <div style="text-align: center; padding: 2.5rem 2rem 1.5rem;">
            <h1 style="font-family: 'Figtree', sans-serif; font-size: 2.5rem; font-weight: 600; color: #A7AE8D; margin: 0 0 0.5rem 0; letter-spacing: 0.03em;">
                ${realm.displayName!"the platform"}
            </h1>
            <p style="font-family: 'Figtree', sans-serif; font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400;">
                Enter your password
            </p>
        </div>

        <div style="padding: 0 2rem 2.5rem;">
            <form id="kc-passwd-form" action="${url.loginAction}" method="post">
                <div style="margin-bottom: 1.25rem;">
                    <label for="password" style="display: block !important; font-family: 'Figtree', sans-serif; font-size: 0.9rem; color: #6b6b6b; margin-bottom: 0.5rem;">
                        Password
                    </label>
                    <input tabindex="1" id="mt-password" name="password" type="password" autocomplete="current-password" autofocus
                           style="display: block !important; width: 100%; padding: 0.75rem 1rem; border: 1px solid #ddd; border-radius: 8px; font-size: 1rem; font-family: 'Figtree', sans-serif; box-sizing: border-box;"
                           aria-invalid="<#if messagesPerField.existsError('password')>true</#if>" />
                    <#if messagesPerField.existsError('password')>
                        <div style="color: #c00; font-size: 0.85rem; margin-top: 0.25rem; font-family: 'Figtree', sans-serif;">
                            ${kcSanitize(messagesPerField.getFirstError('password'))?no_esc}
                        </div>
                    </#if>
                </div>

                <input type="hidden" id="id-hidden-input" name="credentialId" <#if auth.selectedCredential?has_content>value="${auth.selectedCredential}"</#if>/>

                <button tabindex="2" type="submit"
                        style="display: block !important; width: 100%; padding: 0.75rem 1rem; background: #A7AE8D; border: none; border-radius: 8px; color: #fff; font-size: 1.1rem; font-weight: 500; cursor: pointer; font-family: 'Figtree', sans-serif; transition: all 0.2s ease;">
                    Sign in
                </button>
            </form>

            <#-- "Try another way" link -->
            <#if auth?has_content && auth.showTryAnotherWayLink()>
            <div style="text-align: center; margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid #eee; font-family: 'Figtree', sans-serif;">
                <form id="kc-select-try-another-way-form" action="${url.loginAction}" method="post">
                    <input type="hidden" name="tryAnotherWay" value="on"/>
                    <a href="#" id="try-another-way"
                       onclick="document.getElementById('kc-select-try-another-way-form').submit();return false;"
                       style="color: #A7AE8D; text-decoration: none; font-size: 0.95rem; font-weight: 500;">
                        ${msg("doTryAnotherWay","Try another way")}
                    </a>
                </form>
            </div>
            </#if>

            <div style="text-align: center; margin-top: 1rem; font-family: 'Figtree', sans-serif;">
                <a href="#" id="recover-link" style="color: #6b6b6b; text-decoration: none; font-size: 0.9rem;">Forgot password?</a>
            </div>
        </div>

        <script type="text/javascript">
            document.documentElement.style.cssText += 'background: #F3E8D6 !important; background-image: none !important;';
            document.body.style.cssText += 'background: #F3E8D6 !important; background-image: none !important; min-height: 100vh;';

            var loginPage = document.querySelector('.login-pf-page');
            if (loginPage) loginPage.style.cssText += 'background: #F3E8D6 !important; display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; padding: 2rem !important; background-image: none !important;';

            var card = document.querySelector('.card-pf') || document.querySelector('.pf-c-login__main');
            if (card) card.style.cssText += 'background: rgba(255,255,255,0.95) !important; border-radius: 16px !important; box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important; padding: 0 !important; max-width: 480px !important; margin: 0 auto !important; border: none !important;';

            // Hide base template chrome
            ['#kc-header', '.login-pf-page-header', '#kc-header-wrapper',
             '.pf-c-login__main-header', '.login-pf-header'].forEach(function(sel) {
                var el = document.querySelector(sel);
                if (el) el.style.display = 'none';
            });

            // Set up recovery link
            var recoverLink = document.getElementById('recover-link');
            if (recoverLink) {
                var currentHost = window.location.hostname;
                var adminHost = currentHost.replace(/^auth\./, 'admin.');
                recoverLink.href = 'https://' + adminHost + '/recover';
            }
        </script>
    </#if>
</@layout.registrationLayout>
