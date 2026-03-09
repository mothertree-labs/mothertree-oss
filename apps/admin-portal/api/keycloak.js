/**
 * Keycloak Admin API client (Admin Portal subset)
 *
 * Contains only the functions needed for admin operations:
 * - User creation (createUser)
 * - Invitation email (sendInvitationEmail) - redirects to account portal
 * - User listing (listUsers)
 * - User deletion (deleteUser)
 * - Passkey check (checkUserHasPasskey)
 * - Email swap (swapToTenantEmailIfNeeded) - still needed for invitation flow
 * - Notification email (sendNotificationEmail)
 */

const crypto = require('crypto');

const KEYCLOAK_URL = process.env.KEYCLOAK_INTERNAL_URL || process.env.KEYCLOAK_URL;
const KEYCLOAK_REALM = process.env.KEYCLOAK_REALM;
const CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID;
const CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function validateUserId(userId) {
  if (!userId || !UUID_REGEX.test(userId)) {
    throw new Error('Invalid user ID format');
  }
}

let cachedToken = null;
let tokenExpiry = 0;

/**
 * Generate HMAC token for beginSetup endpoint
 * This token is stored as a user attribute and included in setup URLs
 * to prevent unauthenticated access to the email swap endpoint.
 */
function generateBeginSetupToken(userId) {
  const secret = process.env.BEGINSETUP_SECRET || process.env.SESSION_SECRET;
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const hmac = crypto.createHmac('sha256', secret)
    .update(userId + ':' + timestamp)
    .digest('hex');
  return timestamp + ':' + hmac;
}

/**
 * Get service account token for admin operations
 */
async function getServiceToken() {
  if (cachedToken && Date.now() < tokenExpiry - 30000) {
    return cachedToken;
  }

  const tokenUrl = `${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token`;

  const response = await fetch(tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to get service token: ${response.status}`);
  }

  const data = await response.json();
  cachedToken = data.access_token;
  tokenExpiry = Date.now() + (data.expires_in * 1000);

  return cachedToken;
}

/**
 * Create a new user in Keycloak
 */
async function createUser({ firstName, lastName, email, recoveryEmail }) {
  const token = await getServiceToken();
  const usersUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users`;

  console.log('Creating user:', { email, recoveryEmail });

  const response = await fetch(usersUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      username: email,
      email: email,
      firstName: firstName,
      lastName: lastName,
      enabled: true,
      emailVerified: true,
      attributes: {
        recoveryEmail: [recoveryEmail],
        tenantEmail: [email],
      },
      requiredActions: ['webauthn-register-passwordless'],
    }),
  });

  if (response.status === 409) {
    throw new Error('User already exists');
  }

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create user: ${error}`);
  }

  // Get the created user's ID
  const locationHeader = response.headers.get('Location');
  let userId = locationHeader ? locationHeader.split('/').pop() : null;

  if (!userId) {
    // Fallback: search for the user
    const searchResponse = await fetch(`${usersUrl}?username=${encodeURIComponent(email)}`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    const users = await searchResponse.json();
    if (users.length > 0) {
      userId = users[0].id;
    } else {
      throw new Error('User created but could not retrieve ID');
    }
  }

  // Ensure recoveryEmail attribute is set (Keycloak requires full user object for PUT)
  console.log('Updating user attributes for userId:', userId);
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}`;

  // Fetch the full user object first
  const getUserResponse = await fetch(userUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!getUserResponse.ok) {
    throw new Error(`Failed to fetch user for attribute update: ${getUserResponse.status}`);
  }

  const fullUser = await getUserResponse.json();
  console.log('Current user attributes:', JSON.stringify(fullUser.attributes));

  // Merge in the recoveryEmail and tenantEmail attributes
  fullUser.attributes = {
    ...(fullUser.attributes || {}),
    recoveryEmail: [recoveryEmail],
    tenantEmail: [email],
  };

  console.log('Setting user attributes to:', JSON.stringify(fullUser.attributes));

  const updateResponse = await fetch(userUrl, {
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(fullUser),
  });

  if (!updateResponse.ok) {
    const errorText = await updateResponse.text();
    throw new Error(`Failed to store recoveryEmail attribute: ${updateResponse.status} - ${errorText}`);
  }

  // Verify the attribute was actually stored
  const verifyResponse = await fetch(userUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  const verifiedUser = await verifyResponse.json();

  if (!verifiedUser.attributes?.recoveryEmail?.[0]) {
    throw new Error('recoveryEmail attribute was not stored by Keycloak - attribute missing after update');
  }

  if (!verifiedUser.attributes?.tenantEmail?.[0]) {
    throw new Error('tenantEmail attribute was not stored by Keycloak - attribute missing after update');
  }

  console.log('User attributes verified:', JSON.stringify(verifiedUser.attributes));

  return { userId };
}

/**
 * Send invitation email to user's recovery email
 *
 * Strategy: Keycloak's execute-actions-email sends to the user's primary email
 * AND embeds that email in the action token. If we swap the email back before
 * the user clicks the link, Keycloak rejects it with "Invalid email address".
 *
 * Solution:
 * 1. Store the tenant email in an attribute (tenantEmail)
 * 2. Set the user's primary email to the recovery email
 * 3. Send the action token email (goes to recovery email, token contains recovery email)
 * 4. After passkey registration, redirect to account portal's /complete-registration
 * 5. Account portal swaps email back to tenant email on first login
 */
async function sendInvitationEmail(userId) {
  validateUserId(userId);
  const token = await getServiceToken();
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}`;

  // Get user to find recovery email and tenant email
  const userResponse = await fetch(userUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!userResponse.ok) {
    throw new Error(`Failed to get user: ${userResponse.status}`);
  }

  const user = await userResponse.json();
  const tenantEmail = user.attributes?.tenantEmail?.[0] || user.email;
  const recoveryEmail = user.attributes?.recoveryEmail?.[0];

  if (!recoveryEmail) {
    throw new Error('User has no recovery email configured');
  }

  console.log(`Sending invitation: tenantEmail=${tenantEmail}, recoveryEmail=${recoveryEmail}`);

  // Generate HMAC token for beginSetup endpoint security
  const beginSetupToken = generateBeginSetupToken(userId);

  // Store tenant email as attribute and set primary email to recovery email
  // This way the action token will be valid when clicked
  const updateResponse = await fetch(userUrl, {
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      ...user,
      email: recoveryEmail,  // Primary email becomes recovery email for invitation
      attributes: {
        ...user.attributes,
        tenantEmail: [tenantEmail],  // Store tenant email for later
        beginSetupToken: [beginSetupToken],  // HMAC token for secure beginSetup access
        setupUserId: [userId],  // Store userId for email template (ProfileBean doesn't expose id)
      },
    }),
  });

  if (!updateResponse.ok) {
    throw new Error(`Failed to update user email: ${updateResponse.status}`);
  }

  // Send the execute-actions-email (will go to recovery email with valid token)
  // After completing actions, redirect to Account Portal's /complete-registration
  // which handles email swap and redirect to webmail
  const accountUrl = process.env.ACCOUNT_PORTAL_URL || process.env.BASE_URL;
  const redirectUri = `${accountUrl}/complete-registration`;
  const accountClientId = process.env.ACCOUNT_PORTAL_CLIENT_ID || 'account-portal';
  const executeActionsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/execute-actions-email`;

  const emailResponse = await fetch(`${executeActionsUrl}?lifespan=604800&redirect_uri=${encodeURIComponent(redirectUri)}&client_id=${accountClientId}`, {
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(['webauthn-register-passwordless']),
  });

  if (!emailResponse.ok) {
    const error = await emailResponse.text();
    throw new Error(`Failed to send invitation email: ${error}`);
  }

  console.log('Invitation email sent successfully');
  return { success: true };
}

/**
 * List all users in the realm
 */
async function listUsers() {
  const token = await getServiceToken();

  // Fetch actual user count first so we never silently truncate the list
  const countUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/count`;
  const countResponse = await fetch(countUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!countResponse.ok) {
    throw new Error(`Failed to get user count: ${countResponse.status}`);
  }

  const totalUsers = await countResponse.json();
  const max = Math.min(Number.isInteger(totalUsers) && totalUsers > 0 ? totalUsers : 100, 10000);
  const usersUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?max=${max}`;

  const response = await fetch(usersUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    throw new Error(`Failed to list users: ${response.status}`);
  }

  const users = await response.json();

  // Enrich with passkey status
  const enrichedUsers = await Promise.all(users.map(async (user) => {
    const hasPasskey = await checkUserHasPasskey(user.id);
    return {
      id: user.id,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      enabled: user.enabled,
      createdTimestamp: user.createdTimestamp,
      hasPasskey,
      recoveryEmail: user.attributes?.recoveryEmail?.[0],
      userType: user.attributes?.userType?.[0] || 'member',
    };
  }));

  return enrichedUsers;
}

/**
 * Check if user has registered a passkey
 */
async function checkUserHasPasskey(userId) {
  validateUserId(userId);
  const token = await getServiceToken();
  const credentialsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/credentials`;

  const response = await fetch(credentialsUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    return false;
  }

  const credentials = await response.json();
  return credentials.some(cred =>
    cred.type === 'webauthn-passwordless' || cred.type === 'webauthn'
  );
}

/**
 * Ensure the passkey credential is ordered before password in Keycloak.
 *
 * Keycloak 26.5's AuthenticationSelectionResolver picks the first credential
 * by priority (creation order). If a password was provisioned before the
 * passkey (e.g. bootstrap admin), the password form is shown instead of the
 * WebAuthn prompt. Moving the passkey to first fixes this.
 */
async function ensurePasskeyFirst(userId) {
  validateUserId(userId);
  const token = await getServiceToken();
  const credentialsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/credentials`;

  const response = await fetch(credentialsUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    console.error(`ensurePasskeyFirst: failed to fetch credentials for ${userId}: ${response.status}`);
    return;
  }

  const credentials = await response.json();
  const pwIndex = credentials.findIndex(c => c.type === 'password');
  const passkeyIndex = credentials.findIndex(c => c.type === 'webauthn-passwordless');

  if (pwIndex === -1 || passkeyIndex === -1 || passkeyIndex < pwIndex) {
    return; // Nothing to fix
  }

  const passkeyCredId = credentials[passkeyIndex].id;
  console.log(`ensurePasskeyFirst: reordering credentials for ${userId} — moving passkey ${passkeyCredId} to first`);

  const moveResponse = await fetch(
    `${credentialsUrl}/${passkeyCredId}/moveToFirst`,
    {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${token}` },
    }
  );

  if (moveResponse.ok || moveResponse.status === 204) {
    console.log(`ensurePasskeyFirst: passkey moved to first for ${userId}`);
  } else {
    console.error(`ensurePasskeyFirst: moveToFirst failed for ${userId}: ${moveResponse.status}`);
  }
}

/**
 * Delete a user
 */
async function deleteUser(userId) {
  validateUserId(userId);
  const token = await getServiceToken();
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}`;

  const response = await fetch(userUrl, {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    throw new Error(`Failed to delete user: ${response.status}`);
  }

  return { success: true };
}

/**
 * Swap user's email from recovery email to tenant email on first login
 * Called after user completes passkey registration and logs in
 */
async function swapToTenantEmailIfNeeded(userId) {
  validateUserId(userId);
  const token = await getServiceToken();
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}`;

  const response = await fetch(userUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    throw new Error(`Failed to get user: ${response.status}`);
  }

  const user = await response.json();
  const tenantEmail = user.attributes?.tenantEmail?.[0];

  // If user has tenantEmail attribute and it's different from current email, swap
  if (tenantEmail && user.email !== tenantEmail) {
    console.log(`Swapping email for ${user.username}: ${user.email} -> ${tenantEmail}`);

    const updateResponse = await fetch(userUrl, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        ...user,
        email: tenantEmail,
        username: tenantEmail,  // Also update username to tenant email
        attributes: {
          ...user.attributes,
          isRecoveryFlow: [],   // Clear recovery flag
        },
      }),
    });

    if (!updateResponse.ok) {
      throw new Error(`Failed to swap email: ${updateResponse.status}`);
    }

    console.log('Email swapped successfully');
    return { swapped: true, newEmail: tenantEmail };
  }

  return { swapped: false };
}

/**
 * Send a notification email via SMTP
 */
async function sendNotificationEmail(toEmail, subject, message) {
  const nodemailer = require('nodemailer');

  const smtpHost = process.env.SMTP_HOST || 'postfix-internal.infra-mail.svc.cluster.local';
  const smtpPort = process.env.SMTP_PORT || 587;
  const smtpFrom = process.env.SMTP_FROM || `noreply@${process.env.TENANT_DOMAIN || 'example.com'}`;
  const smtpFromName = process.env.SMTP_FROM_NAME || 'MotherTree';

  try {
    const transporter = nodemailer.createTransport({
      host: smtpHost,
      port: smtpPort,
      secure: false,
      tls: { rejectUnauthorized: false },
    });

    await transporter.sendMail({
      from: `"${smtpFromName}" <${smtpFrom}>`,
      to: toEmail,
      subject: subject,
      text: message,
    });

    return { sent: true };
  } catch (error) {
    console.error(`[NOTIFICATION EMAIL] Failed to send:`, error.message);
    return { sent: false, error: error.message };
  }
}

module.exports = {
  createUser,
  sendInvitationEmail,
  listUsers,
  deleteUser,
  checkUserHasPasskey,
  ensurePasskeyFirst,
  swapToTenantEmailIfNeeded,
  sendNotificationEmail,
};
