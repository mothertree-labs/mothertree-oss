/**
 * Centralized CSS selectors for all Mothertree apps.
 * Organized by application/page to make maintenance easy.
 */

export const selectors = {
  // ─── Keycloak Login Flow ───────────────────────────────────────────
  keycloak: {
    // Step 1: Username entry (login-username.ftl)
    usernameInput: '#username',
    continueBtn: '.continue-btn',

    // Step 2: WebAuthn page may appear — click "try another way"
    tryAnotherWay: '#try-another-way',

    // Step 2b: Select authenticator page (select-authenticator.ftl)
    passwordAuthLink: 'a.authenticator-link:has(.authenticator-name:text("Password"))',

    // Step 3: Password entry (login-password.ftl)
    passwordInput: '#mt-password',
    passwordForm: '#kc-passwd-form',
    passwordSubmitBtn: '#kc-passwd-form button[type="submit"]',

    // login.ftl (direct login page with passkey)
    adminLoginToggle: '#show-admin-login',
    adminLoginForm: '#admin-login-form',
    adminPasswordInput: '#admin-login-form #password',
    passKeyLoginBtn: '#passkey-login-btn',
    magicLinkLogin: '#magic-link-login',
  },

  // ─── Account Portal ────────────────────────────────────────────────
  accountPortal: {
    // Login page (login.ejs)
    signInBtn: 'a[href="/auth/login"]',

    // Home/Dashboard (home.ejs)
    welcomeHeading: 'h1:has-text("Welcome,")',
    signOutLink: 'a[href="/auth/logout"]',
    appCardChat: 'a:has(h2:text("Chat"))',
    appCardEmail: 'a:has(h2:text("Email"))',
    appCardDocs: 'a:has(h2:text("Documents"))',
    appCardFiles: 'a:has(h2:text("Files"))',
    appCardVideo: 'a:has(h2:text("Video"))',
    appCardCalendar: 'a:has(h2:text("Calendar"))',
    appCardDevicePasswords: 'a[href="/app-passwords"]',

    // Device Passwords (app-passwords.ejs)
    devicePasswordHeading: 'h1:has-text("Device Passwords")',
    createForm: '#createForm',
    deviceNameInput: '#deviceName',
    createPasswordBtn: '#createForm button[type="submit"]',
    generatedPassword: '#generatedPassword',
    passwordValue: '#passwordValue',
    copyConfirm: '#copyConfirm',
    passwordsList: '#passwordsList',
    formError: '#formError',

    // Recovery (recover.ejs)
    recoverHeading: 'p:has-text("Account Recovery")',
    tenantEmailInput: '#tenantEmail',
    recoveryEmailInput: '#recoveryEmail',
    sendRecoveryBtn: 'button:has-text("Send Recovery Link")',
  },

  // ─── Admin Portal ──────────────────────────────────────────────────
  adminPortal: {
    // Dashboard (dashboard.ejs)
    adminHeading: 'h1:has-text("mothertree admin")',
    signOutLink: 'a[href="/auth/logout"]',

    // Invite form
    inviteForm: '#inviteForm',
    firstNameInput: '#inviteForm input[name="firstName"]',
    lastNameInput: '#inviteForm input[name="lastName"]',
    emailUsernameInput: '#emailUsername',
    emailDomain: '#emailDomain',
    fullEmailHidden: '#fullEmail',
    recoveryEmailInput: '#inviteForm input[name="recoveryEmail"]',
    inviteSubmitBtn: '#inviteForm button[type="submit"]',
    formMessage: '#formMessage',

    // Members list
    membersList: '#membersList',
    backfillBtn: '#backfillBtn',

    // Quota modal
    quotaModal: '#quotaModal',
    quotaModalEmail: '#quotaModalEmail',
    quotaInput: '#quotaInput',
    quotaCancelBtn: '#quotaCancelBtn',
    quotaSaveBtn: '#quotaSaveBtn',

    // Guests list
    guestsList: '#guestsList',
    guestRegisterLink: '#guestRegisterLink',

    // Dynamic selectors (use with page.locator())
    editQuotaBtn: '[data-action="edit-quota"]',
    deleteUserBtn: '[data-action="delete-user"]',
  },

  // ─── Nextcloud Calendar ────────────────────────────────────────────
  nextcloudCalendar: {
    newEventBtn: 'button:has-text("New event")',
    eventTitleInput: 'input[placeholder*="Event title"], input[placeholder*="event title"]',
    addAttendeeInput: 'input[placeholder*="Search for"], input[placeholder*="search for"], input[placeholder*="Add attendee"]',
    saveBtn: 'button.primary:has-text("Save"), button[type="submit"]:has-text("Save")',
    acceptBtn: 'button:has-text("Accept")',
    declineBtn: 'button:has-text("Decline")',
    calendarEvent: '.fc-event',
  },

  // ─── Guest Registration ────────────────────────────────────────────
  guest: {
    registerForm: '#registerForm',
    firstNameInput: '#firstName',
    lastNameInput: '#lastName',
    emailInput: '#emailInput',
    policyConsent: '#policyConsent',
    submitBtn: '#submitBtn',
    errorAlert: '#errorAlert',
    errorMessage: '#errorMessage',
    successState: '#successState',
    formState: '#formState',
    loginLink: '#loginLink',
  },
};
