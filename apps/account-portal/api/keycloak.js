/**
 * Keycloak Admin API client (Account Portal subset)
 *
 * Contains only the functions needed for user self-service:
 * - Email swap (swapToTenantEmailIfNeeded)
 * - Account recovery (initiateAccountRecovery)
 * - Guest user creation (createGuestUser)
 * - User lookup (findUserByEmail)
 * - Role management (assignRealmRole, removeRealmRole)
 * - Notification email (sendNotificationEmail)
 */

const crypto = require('crypto');

const KEYCLOAK_URL = process.env.KEYCLOAK_URL;
const KEYCLOAK_REALM = process.env.KEYCLOAK_REALM;
const CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID;
const CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET;

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
 * Swap user's email from recovery email to tenant email on first login
 * Called after user completes passkey registration and logs in
 */
async function swapToTenantEmailIfNeeded(userId) {
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
          tenantEmail: [],      // Clear the attribute since it's now applied
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
 * Find user by their tenant email address
 */
async function findUserByEmail(email) {
  const token = await getServiceToken();
  const usersUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?email=${encodeURIComponent(email)}&exact=true`;

  const response = await fetch(usersUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!response.ok) {
    throw new Error(`Failed to search users: ${response.status}`);
  }

  const users = await response.json();
  return users.length > 0 ? users[0] : null;
}

/**
 * Send a notification email via SMTP
 */
async function sendNotificationEmail(toEmail, subject, message) {
  const nodemailer = require('nodemailer');

  // SMTP configuration - uses the same internal postfix as Keycloak
  const smtpHost = process.env.SMTP_HOST || 'postfix-internal.infra-mail.svc.cluster.local';
  const smtpPort = process.env.SMTP_PORT || 587;
  const smtpFrom = process.env.SMTP_FROM || `noreply@${process.env.TENANT_DOMAIN || 'example.com'}`;
  const smtpFromName = process.env.SMTP_FROM_NAME || 'MotherTree';

  console.log(`[NOTIFICATION EMAIL] Sending to: ${toEmail}`);
  console.log(`[NOTIFICATION EMAIL] Subject: ${subject}`);
  console.log(`[NOTIFICATION EMAIL] SMTP: ${smtpHost}:${smtpPort}`);

  try {
    const transporter = nodemailer.createTransport({
      host: smtpHost,
      port: smtpPort,
      secure: false,  // Internal cluster communication
      tls: {
        rejectUnauthorized: false,  // Internal service
      },
    });

    await transporter.sendMail({
      from: `"${smtpFromName}" <${smtpFrom}>`,
      to: toEmail,
      subject: subject,
      text: message,
      html: `
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
          <h1 style="color: #4a6741; font-size: 24px; margin-bottom: 20px;">MotherTree</h1>
          <div style="background: #fff7ed; border: 1px solid #fed7aa; border-radius: 8px; padding: 16px; margin-bottom: 20px;">
            <p style="color: #9a3412; margin: 0; font-size: 14px;">
              <strong>Security Notice</strong>
            </p>
          </div>
          <p style="color: #3d3d3d; line-height: 1.6;">${message}</p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 20px 0;">
          <p style="color: #999; font-size: 12px;">
            If you did not request this, please contact support immediately.
          </p>
        </div>
      `,
    });

    console.log(`[NOTIFICATION EMAIL] Sent successfully to ${toEmail}`);
    return { sent: true };
  } catch (error) {
    console.error(`[NOTIFICATION EMAIL] Failed to send:`, error.message);
    // Don't fail the recovery flow if notification fails
    return { sent: false, error: error.message };
  }
}

/**
 * Initiate account recovery for a user
 *
 * This validates both the tenant email and recovery email,
 * then sends a passkey re-registration link to the recovery email.
 * Also sends a notification to the tenant email.
 */
async function initiateAccountRecovery({ tenantEmail, recoveryEmail }) {
  const token = await getServiceToken();

  // 1. Find the user by tenant email
  console.log(`Account recovery requested for: ${tenantEmail}`);

  // First check if user exists with tenantEmail as their current email
  let user = await findUserByEmail(tenantEmail);

  // Also check if the tenantEmail is stored in the tenantEmail attribute
  // (in case user is mid-registration with recovery email as primary)
  if (!user) {
    const usersUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users?max=500`;
    const response = await fetch(usersUrl, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    const allUsers = await response.json();
    user = allUsers.find(u => u.attributes?.tenantEmail?.[0] === tenantEmail);
  }

  if (!user) {
    throw new Error('No account found with that email address');
  }

  // 2. Validate recovery email matches
  const storedRecoveryEmail = user.attributes?.recoveryEmail?.[0];

  if (!storedRecoveryEmail) {
    throw new Error('This account does not have a recovery email configured');
  }

  if (storedRecoveryEmail.toLowerCase() !== recoveryEmail.toLowerCase()) {
    throw new Error('The recovery email address does not match our records');
  }

  console.log(`Recovery email validated for user ${user.id}`);

  // 3. Check if user has any existing passkeys and remove them
  // (they need to register fresh ones)
  const credentialsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${user.id}/credentials`;
  const credResponse = await fetch(credentialsUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  const credentials = await credResponse.json();

  // Remove existing webauthn credentials
  for (const cred of credentials) {
    if (cred.type === 'webauthn-passwordless' || cred.type === 'webauthn') {
      console.log(`Removing old ${cred.type} credential: ${cred.id}`);
      await fetch(`${credentialsUrl}/${cred.id}`, {
        method: 'DELETE',
        headers: { 'Authorization': `Bearer ${token}` },
      });
    }
  }

  // 4. Check if user is already in "swapped" state from a previous failed attempt
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${user.id}`;
  const isAlreadySwapped = user.email?.toLowerCase() === recoveryEmail.toLowerCase() &&
                           user.attributes?.tenantEmail?.[0]?.toLowerCase() === tenantEmail.toLowerCase();

  if (isAlreadySwapped) {
    console.log('User is already in swapped state from previous attempt, refreshing token');
    // Refresh the HMAC token even when already swapped
    const beginSetupToken = generateBeginSetupToken(user.id);
    const refreshTokenResponse = await fetch(userUrl, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        ...user,
        attributes: {
          ...user.attributes,
          beginSetupToken: [beginSetupToken],
        },
      }),
    });
    if (!refreshTokenResponse.ok) {
      console.error('Failed to refresh beginSetup token, but continuing...');
    }
  } else {
    // Generate HMAC token for beginSetup endpoint security
    const beginSetupToken = generateBeginSetupToken(user.id);

    // Store the original email and swap to recovery email
    console.log(`Swapping email from ${user.email} to ${recoveryEmail}`);

    const updateResponse = await fetch(userUrl, {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        ...user,
        email: recoveryEmail,  // Swap to recovery email for the action token
        requiredActions: ['webauthn-register-passwordless'],
        attributes: {
          ...user.attributes,
          tenantEmail: [tenantEmail],  // Store tenant email for restoration
          isRecoveryFlow: ['true'],    // Flag for email template to show recovery messaging
          beginSetupToken: [beginSetupToken],  // HMAC token for secure beginSetup access
        },
      }),
    });

    if (!updateResponse.ok) {
      throw new Error(`Failed to prepare user for recovery: ${updateResponse.status}`);
    }

    // Re-fetch user after update for consistency
    const updatedUserResponse = await fetch(userUrl, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    user = await updatedUserResponse.json();
  }

  // Ensure required actions are set and recovery flag is set
  const ensureActionsResponse = await fetch(userUrl, {
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      ...user,
      requiredActions: ['webauthn-register-passwordless'],
      attributes: {
        ...user.attributes,
        isRecoveryFlow: ['true'],
      },
    }),
  });

  if (!ensureActionsResponse.ok) {
    console.error('Failed to ensure required actions, but continuing...');
  }

  // 5. Send the execute-actions-email (will go to recovery email)
  const baseUrl = process.env.BASE_URL;
  const webmailHost = process.env.WEBMAIL_HOST;
  // After passkey registration, redirect user to webmail (email will already be swapped back)
  const redirectUri = webmailHost ? `https://${webmailHost}` : baseUrl;
  const clientId = process.env.KEYCLOAK_CLIENT_ID || 'account-portal';
  const executeActionsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${user.id}/execute-actions-email`;

  const emailResponse = await fetch(
    `${executeActionsUrl}?lifespan=86400&redirect_uri=${encodeURIComponent(redirectUri)}&client_id=${clientId}`,
    {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(['webauthn-register-passwordless']),
    }
  );

  if (!emailResponse.ok) {
    const error = await emailResponse.text();

    // Try to restore the original email to avoid leaving user in bad state
    console.error('Email send failed, attempting to restore original email...');
    try {
      const restoreResponse = await fetch(userUrl, {
        method: 'PUT',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          ...user,
          email: tenantEmail,
          attributes: {
            ...user.attributes,
            tenantEmail: [],
            isRecoveryFlow: [],
          },
        }),
      });
      if (restoreResponse.ok) {
        console.log('Successfully restored original email after failed send');
      }
    } catch (restoreError) {
      console.error('Failed to restore original email:', restoreError.message);
    }

    throw new Error(`Failed to send recovery email: ${error}`);
  }

  console.log(`Recovery email sent to ${recoveryEmail}`);

  // 6. DON'T swap email back here - leave it as recovery email
  // The email template routes through /beginSetup which swaps the email
  // BEFORE redirecting to Keycloak.

  // 7. Send notification to tenant email
  await sendNotificationEmail(
    tenantEmail,
    'MotherTree Account Recovery Initiated',
    `A passkey recovery was requested for your MotherTree account (${tenantEmail}). ` +
    `A recovery link has been sent to your recovery email address. ` +
    `If you did not request this, please contact support immediately.`
  );

  return {
    success: true,
    message: 'Recovery link sent to your recovery email address',
    recoveryEmailHint: recoveryEmail.replace(/(.{2}).*(@.*)/, '$1***$2'),
  };
}

/**
 * Assign a realm role to a user
 */
async function assignRealmRole(userId, roleName) {
  const token = await getServiceToken();

  // Get the role object first
  const roleUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/roles/${roleName}`;
  const roleResponse = await fetch(roleUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!roleResponse.ok) {
    throw new Error(`Role '${roleName}' not found: ${roleResponse.status}`);
  }

  const role = await roleResponse.json();

  // Assign the role to the user
  const mappingsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/role-mappings/realm`;
  const response = await fetch(mappingsUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([role]),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to assign role '${roleName}': ${error}`);
  }
}

/**
 * Remove a realm role from a user
 */
async function removeRealmRole(userId, roleName) {
  const token = await getServiceToken();

  // Get the role object first
  const roleUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/roles/${roleName}`;
  const roleResponse = await fetch(roleUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });

  if (!roleResponse.ok) {
    // Role doesn't exist, nothing to remove
    if (roleResponse.status === 404) return;
    throw new Error(`Failed to get role '${roleName}': ${roleResponse.status}`);
  }

  const role = await roleResponse.json();

  // Remove the role from the user
  const mappingsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/role-mappings/realm`;
  const response = await fetch(mappingsUrl, {
    method: 'DELETE',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify([role]),
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to remove role '${roleName}': ${error}`);
  }
}

/**
 * Create a guest user in Keycloak
 * Unlike regular user creation, this:
 * - Uses the guest's own email (no tenant domain email)
 * - Does NOT provision in Stalwart (no mailbox)
 * - Assigns guest-user role instead of docs-user
 * - Sets userType attribute to 'guest'
 * - Requires email verification + passkey registration
 */
async function createGuestUser({ email, firstName, lastName, redirectUri }) {
  const token = await getServiceToken();
  const usersUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users`;

  console.log('Creating guest user:', { email });

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
      emailVerified: false,
      attributes: {
        userType: ['guest'],
      },
      requiredActions: ['VERIFY_EMAIL', 'webauthn-register-passwordless'],
    }),
  });

  if (response.status === 409) {
    throw new Error('A user with this email already exists');
  }

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Failed to create guest user: ${error}`);
  }

  // Get the created user's ID
  const locationHeader = response.headers.get('Location');
  let userId = locationHeader ? locationHeader.split('/').pop() : null;

  if (!userId) {
    const searchResponse = await fetch(`${usersUrl}?username=${encodeURIComponent(email)}`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    const users = await searchResponse.json();
    if (users.length > 0) {
      userId = users[0].id;
    } else {
      throw new Error('Guest user created but could not retrieve ID');
    }
  }

  // Persist userType attribute (Keycloak may not store attributes from POST)
  const userUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}`;
  const getUserResponse = await fetch(userUrl, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  if (getUserResponse.ok) {
    const fullUser = await getUserResponse.json();
    fullUser.attributes = {
      ...(fullUser.attributes || {}),
      userType: ['guest'],
    };
    await fetch(userUrl, {
      method: 'PUT',
      headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(fullUser),
    });
    console.log('Set userType attribute to guest');
  }

  // Assign guest-user role and remove docs-user default role
  try {
    await assignRealmRole(userId, 'guest-user');
    console.log('Assigned guest-user role');
  } catch (err) {
    console.error('Failed to assign guest-user role:', err.message);
  }

  try {
    await removeRealmRole(userId, 'docs-user');
    console.log('Removed docs-user default role from guest');
  } catch (err) {
    console.error('Failed to remove docs-user role (may not exist):', err.message);
  }

  // Send execute-actions-email for verification + passkey registration
  const baseUrl = process.env.BASE_URL;
  const finalRedirect = redirectUri || baseUrl;
  const clientId = process.env.KEYCLOAK_CLIENT_ID || 'account-portal';
  const executeActionsUrl = `${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users/${userId}/execute-actions-email`;

  const emailResponse = await fetch(
    `${executeActionsUrl}?lifespan=604800&redirect_uri=${encodeURIComponent(finalRedirect)}&client_id=${clientId}`,
    {
      method: 'PUT',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(['VERIFY_EMAIL', 'webauthn-register-passwordless']),
    }
  );

  if (!emailResponse.ok) {
    const error = await emailResponse.text();
    console.error('Failed to send guest registration email:', error);
    // Don't throw - user is created, they can recover later
  } else {
    console.log('Guest registration email sent successfully');
  }

  return { userId };
}

module.exports = {
  swapToTenantEmailIfNeeded,
  initiateAccountRecovery,
  createGuestUser,
  findUserByEmail,
  sendNotificationEmail,
  assignRealmRole,
  removeRealmRole,
};
