<#--
    Platform Magic-Link "Check Your Email" Page
    Shown by the Phase Two magic-link authenticator after it sends a sign-in link.
    The user waits here while checking their inbox.

    All styling uses inline styles + JS because the base template renders the
    "header" section inside an <h1> tag where <style> blocks don't reliably apply.
-->
<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=false displayRequiredFields=false; section>
    <#if section = "header">
        ${realm.displayName!"the platform"}
    <#elseif section = "form">
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />

        <div style="text-align: center; padding: 2.5rem 2rem 1.5rem;">
            <h1 style="font-family: 'Figtree', sans-serif; font-size: 2.5rem; font-weight: 600; color: #A7AE8D; margin: 0 0 0.5rem 0; letter-spacing: 0.03em;">
                ${realm.displayName!"the platform"}
            </h1>
            <p style="font-family: 'Figtree', sans-serif; font-size: 1.1rem; color: #6b6b6b; margin: 0; font-weight: 400;">
                Check your email
            </p>
        </div>

        <div style="padding: 0 2rem 2.5rem; text-align: center;">
            <#-- Envelope icon in sage circle -->
            <div style="width: 64px; height: 64px; margin: 0 auto 1.5rem; background: #EDF3EB; border-radius: 50%; display: flex; align-items: center; justify-content: center;">
                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                    <path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z" fill="#A7AE8D"/>
                </svg>
            </div>

            <#-- User's email address in a styled box -->
            <#if auth?has_content && auth.attemptedUsername?has_content>
                <div style="font-family: 'Figtree', sans-serif; background: #f5f5f5; border: 1px solid #e5e5e5; border-radius: 8px; padding: 0.75rem 1rem; margin: 0 auto 1.5rem; display: inline-block; max-width: 100%; word-break: break-all; font-size: 1rem; color: #333;">
                    ${auth.attemptedUsername}
                </div>
            </#if>

            <#-- Confirmation message -->
            <div style="font-family: 'Figtree', sans-serif; font-size: 1rem; color: #6b6b6b; margin-bottom: 1.5rem; line-height: 1.6;">
                We've sent a sign-in link to your email address. Click the link in the email to continue.
            </div>

            <div style="font-family: 'Figtree', sans-serif; font-size: 0.9rem; color: #999; margin-bottom: 2rem; line-height: 1.5;">
                The link will expire shortly. If you don't see the email, check your spam folder.
            </div>

            <#-- Start over link -->
            <div style="padding-top: 1rem; border-top: 1px solid #eee; font-family: 'Figtree', sans-serif;">
                <a href="${url.loginRestartFlowUrl}"
                   style="color: #A7AE8D; text-decoration: none; font-size: 0.95rem; font-weight: 500;">
                    Start over
                </a>
            </div>
        </div>

        <#-- Page styling overrides (same pattern as webauthn-authenticate.ftl) -->
        <script type="text/javascript">
            document.documentElement.style.cssText += 'background: #F3E8D6 !important; background-image: none !important;';
            document.body.style.cssText += 'background: #F3E8D6 !important; background-image: none !important; min-height: 100vh;';

            var loginPage = document.querySelector('.login-pf-page');
            if (loginPage) loginPage.style.cssText += 'background: #F3E8D6 !important; display: flex !important; flex-direction: column !important; align-items: center !important; justify-content: center !important; padding: 2rem !important; background-image: none !important;';

            var card = document.querySelector('.card-pf') || document.querySelector('.pf-c-login__main');
            if (card) card.style.cssText += 'background: rgba(255,255,255,0.95) !important; border-radius: 16px !important; box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important; padding: 0 !important; max-width: 480px !important; margin: 0 auto !important; border: none !important;';

            // Hide base template elements
            ['#kc-header', '.login-pf-page-header', '#kc-header-wrapper', '#kc-username',
             '.kc-username', '#kc-attempted-username', '.pf-c-login__main-header',
             '.login-pf-header'].forEach(function(sel) {
                var el = document.querySelector(sel);
                if (el) el.style.display = 'none';
            });

            // Hide any "Restart login" links rendered by the base template
            document.querySelectorAll('a').forEach(function(a) {
                if (a.textContent.trim() === 'Restart login' || a.id === 'reset-login') {
                    var p = a.closest('div') || a.parentElement;
                    if (p) p.style.display = 'none';
                }
            });
        </script>
    </#if>
</@layout.registrationLayout>
