<#import "template.ftl" as layout>
<@layout.registrationLayout; section>
    <#if section = "header">
        <link rel="stylesheet" href="${url.resourcesPath}/css/styles.css" />
        <link rel="stylesheet" href="${url.resourcesPath}/css/fonts.css" />
        <style>
            html.login-pf, html.login-pf body, body, .login-pf-page {
                background: #f2efe8 !important;
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
            .card-pf, .login-pf-page .card-pf {
                background: rgba(255,255,255,0.9) !important;
                border-radius: 16px !important;
                box-shadow: 0 4px 24px rgba(0,0,0,0.08) !important;
                padding: 2.5rem !important;
                max-width: 420px !important;
                margin: 0 auto !important;
            }
            .platform-header { 
                text-align: center; 
                margin-bottom: 1.5rem;
            }
            .platform-title { 
                font-family: 'Tomorrow', sans-serif;
                font-size: 2rem; font-weight: 400; color: #4a6741; 
                margin: 0 0 0.5rem 0; letter-spacing: 0.03em;
            }
            .logout-message {
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem; color: #6b6b6b; 
                text-align: center;
                margin-bottom: 1.5rem;
            }
            #kc-logout {
                display: block !important;
                width: 100%;
                padding: 0.875rem 2rem !important;
                background: #4a6741 !important;
                border: none !important;
                border-radius: 8px !important;
                color: #fff !important;
                font-family: 'Instrument Sans', sans-serif;
                font-size: 1.1rem !important;
                font-weight: 500 !important;
                cursor: pointer !important;
                transition: all 0.2s ease !important;
                box-shadow: 0 4px 12px rgba(74, 103, 65, 0.3) !important;
            }
            #kc-logout:hover {
                background: #3d5636 !important;
                transform: translateY(-1px);
            }
            .pf-c-login__footer, .login-pf-page-footer { background: transparent !important; }
        </style>
        <div class="platform-header">
            <h1 class="platform-title">${realmDisplayName!"the platform"}</h1>
        </div>
    <#elseif section = "form">
        <div id="kc-logout">
            <p class="logout-message">${msg("logoutConfirmHeader")}</p>
            <form class="form-actions" action="${url.logoutConfirmAction}" method="POST">
                <input type="hidden" name="session_code" value="${logoutConfirm.code}">
                <input tabindex="4" id="kc-logout" class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!} ${properties.kcButtonLargeClass!}" name="confirmLogout" type="submit" value="${msg("doLogout")}"/>
            </form>
        </div>
    </#if>
</@layout.registrationLayout>
