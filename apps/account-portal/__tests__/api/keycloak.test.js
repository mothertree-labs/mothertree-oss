/**
 * Tests for api/keycloak.js
 *
 * These tests mock the global fetch() to simulate Keycloak Admin API responses.
 * Environment variables are set before requiring the module (it reads them at load time).
 */

// Set env vars BEFORE requiring the module
process.env.KEYCLOAK_URL = 'http://keycloak.test';
process.env.KEYCLOAK_REALM = 'test-realm';
process.env.KEYCLOAK_CLIENT_ID = 'test-client';
process.env.KEYCLOAK_CLIENT_SECRET = 'test-secret';
process.env.KEYCLOAK_INTERNAL_URL = '';
process.env.SESSION_SECRET = 'test-session-secret';
process.env.BEGINSETUP_SECRET = 'test-beginsetup-secret';
process.env.BASE_URL = 'https://account.test.example.com';
process.env.WEBMAIL_HOST = 'webmail.test.example.com';
process.env.TENANT_DOMAIN = 'example.com';
process.env.SMTP_HOST = 'smtp.test';
process.env.SMTP_PORT = '587';
process.env.SMTP_FROM = 'noreply@example.com';
process.env.SMTP_FROM_NAME = 'TestTree';

const VALID_UUID = '550e8400-e29b-41d4-a716-446655440000';

// Helper to create a mock fetch response
function mockResponse(status, body, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
    headers: {
      get: (name) => {
        // Case-insensitive header lookup
        const key = Object.keys(headers).find(k => k.toLowerCase() === name.toLowerCase());
        return key ? headers[key] : null;
      },
    },
  };
}

// Token response for getServiceToken
const TOKEN_RESPONSE = {
  access_token: 'mock-access-token',
  expires_in: 300,
  token_type: 'Bearer',
};

describe('keycloak.js', () => {
  let keycloak;
  let originalFetch;

  beforeEach(() => {
    originalFetch = global.fetch;
    global.fetch = jest.fn();
    // Reset all module caches to ensure fresh state (especially cached token)
    jest.resetModules();
    keycloak = require('../../api/keycloak');
  });

  afterEach(() => {
    global.fetch = originalFetch;
    jest.restoreAllMocks();
  });

  // ---- findUserByEmail ----

  describe('findUserByEmail', () => {
    it('returns user found by primary email search', async () => {
      const mockUser = { id: VALID_UUID, email: 'alice@example.com', username: 'alice' };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [mockUser]));

      const result = await keycloak.findUserByEmail('alice@example.com');
      expect(result).toEqual(mockUser);
      expect(global.fetch).toHaveBeenCalledTimes(2);
    });

    it('falls back to tenantEmail attribute search when primary search returns empty', async () => {
      const mockUser = { id: VALID_UUID, email: 'recovery@gmail.com', attributes: { tenantEmail: ['alice@example.com'] } };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, []))
        .mockResolvedValueOnce(mockResponse(200, [mockUser]));

      const result = await keycloak.findUserByEmail('alice@example.com');
      expect(result).toEqual(mockUser);
    });

    it('returns null when no user found by either search', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, []))
        .mockResolvedValueOnce(mockResponse(200, []));

      const result = await keycloak.findUserByEmail('nonexistent@example.com');
      expect(result).toBeNull();
    });

    it('returns null when attribute search fails', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, []))
        .mockResolvedValueOnce(mockResponse(500, 'Internal Server Error'));

      const result = await keycloak.findUserByEmail('nobody@example.com');
      expect(result).toBeNull();
    });

    it('throws when primary email search fails', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(500, 'error'));

      await expect(keycloak.findUserByEmail('fail@example.com'))
        .rejects.toThrow('Failed to search users: 500');
    });
  });

  // ---- swapToTenantEmailIfNeeded ----

  describe('swapToTenantEmailIfNeeded', () => {
    it('swaps email when tenantEmail attribute differs from current email', async () => {
      const user = {
        id: VALID_UUID,
        email: 'recovery@gmail.com',
        username: 'recovery@gmail.com',
        attributes: { tenantEmail: ['alice@example.com'] },
      };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, user))
        .mockResolvedValueOnce(mockResponse(204, ''));

      const result = await keycloak.swapToTenantEmailIfNeeded(VALID_UUID);
      expect(result).toEqual({ swapped: true, newEmail: 'alice@example.com' });

      const putCall = global.fetch.mock.calls[2];
      expect(putCall[0]).toContain(`/users/${VALID_UUID}`);
      const putBody = JSON.parse(putCall[1].body);
      expect(putBody.email).toBe('alice@example.com');
      expect(putBody.username).toBe('alice@example.com');
      expect(putBody.attributes.isRecoveryFlow).toEqual([]);
    });

    it('returns { swapped: false } when email matches tenantEmail', async () => {
      const user = {
        id: VALID_UUID,
        email: 'alice@example.com',
        attributes: { tenantEmail: ['alice@example.com'] },
      };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, user));

      const result = await keycloak.swapToTenantEmailIfNeeded(VALID_UUID);
      expect(result).toEqual({ swapped: false });
    });

    it('returns { swapped: false } when no tenantEmail attribute', async () => {
      const user = { id: VALID_UUID, email: 'alice@example.com', attributes: {} };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, user));

      const result = await keycloak.swapToTenantEmailIfNeeded(VALID_UUID);
      expect(result).toEqual({ swapped: false });
    });

    it('throws on invalid user ID format', async () => {
      await expect(keycloak.swapToTenantEmailIfNeeded('not-a-uuid'))
        .rejects.toThrow('Invalid user ID format');
    });

    it('throws when GET user fails', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(404, 'Not Found'));

      await expect(keycloak.swapToTenantEmailIfNeeded(VALID_UUID))
        .rejects.toThrow('Failed to get user: 404');
    });

    it('throws when PUT (swap) fails', async () => {
      const user = {
        id: VALID_UUID,
        email: 'recovery@gmail.com',
        attributes: { tenantEmail: ['alice@example.com'] },
      };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, user))
        .mockResolvedValueOnce(mockResponse(500, 'error'));

      await expect(keycloak.swapToTenantEmailIfNeeded(VALID_UUID))
        .rejects.toThrow('Failed to swap email: 500');
    });
  });

  // ---- ensurePasskeyFirst ----

  describe('ensurePasskeyFirst', () => {
    it('moves passkey to first when password comes before it', async () => {
      const credentials = [
        { id: 'cred-pw', type: 'password' },
        { id: 'cred-pk', type: 'webauthn-passwordless' },
      ];

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, credentials))
        .mockResolvedValueOnce(mockResponse(204, ''));

      await keycloak.ensurePasskeyFirst(VALID_UUID);

      const moveCall = global.fetch.mock.calls[2];
      expect(moveCall[0]).toContain('/cred-pk/moveToFirst');
      expect(moveCall[1].method).toBe('POST');
    });

    it('does nothing when passkey is already before password', async () => {
      const credentials = [
        { id: 'cred-pk', type: 'webauthn-passwordless' },
        { id: 'cred-pw', type: 'password' },
      ];

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, credentials));

      await keycloak.ensurePasskeyFirst(VALID_UUID);
      expect(global.fetch).toHaveBeenCalledTimes(2);
    });

    it('does nothing when there is no password credential', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [{ id: 'cred-pk', type: 'webauthn-passwordless' }]));

      await keycloak.ensurePasskeyFirst(VALID_UUID);
      expect(global.fetch).toHaveBeenCalledTimes(2);
    });

    it('does nothing when there is no passkey credential', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [{ id: 'cred-pw', type: 'password' }]));

      await keycloak.ensurePasskeyFirst(VALID_UUID);
      expect(global.fetch).toHaveBeenCalledTimes(2);
    });

    it('returns silently on fetch error (non-throwing)', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(500, 'error'));

      await keycloak.ensurePasskeyFirst(VALID_UUID);
    });

    it('throws on invalid user ID', async () => {
      await expect(keycloak.ensurePasskeyFirst('bad-id'))
        .rejects.toThrow('Invalid user ID format');
    });
  });

  // ---- sendNotificationEmail ----

  describe('sendNotificationEmail', () => {
    function mockNodemailer(sendMailFn) {
      // Load nodemailer into cache if not already loaded, then override exports
      const path = require.resolve('nodemailer');
      require('nodemailer');
      const original = require.cache[path].exports;
      require.cache[path].exports = {
        createTransport: () => ({ sendMail: sendMailFn }),
      };
      return () => {
        if (require.cache[path]) {
          require.cache[path].exports = original;
        }
      };
    }

    it('calls nodemailer and HTML-escapes the message', async () => {
      const mockSendMail = jest.fn().mockResolvedValue({ messageId: 'test-123' });
      const restore = mockNodemailer(mockSendMail);

      try {
        const result = await keycloak.sendNotificationEmail(
          'user@example.com',
          'Test Subject',
          '<script>alert("xss")</script>'
        );

        expect(result).toEqual({ sent: true });
        expect(mockSendMail).toHaveBeenCalledTimes(1);

        const mailOpts = mockSendMail.mock.calls[0][0];
        expect(mailOpts.to).toBe('user@example.com');
        expect(mailOpts.subject).toBe('Test Subject');
        expect(mailOpts.text).toBe('<script>alert("xss")</script>');
        expect(mailOpts.html).not.toContain('<script>');
        expect(mailOpts.html).toContain('&lt;script&gt;');
        expect(mailOpts.html).toContain('Security Notice');
      } finally {
        restore();
      }
    });

    it('returns { sent: false } on transport error', async () => {
      const mockSendMail = jest.fn().mockRejectedValue(new Error('SMTP connection refused'));
      const restore = mockNodemailer(mockSendMail);

      try {
        const result = await keycloak.sendNotificationEmail('user@example.com', 'Test', 'body');
        expect(result).toEqual({ sent: false, error: 'SMTP connection refused' });
      } finally {
        restore();
      }
    });
  });

  // ---- assignRealmRole ----

  describe('assignRealmRole', () => {
    it('fetches role and assigns it to user', async () => {
      const role = { id: 'role-id', name: 'docs-user' };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, role))
        .mockResolvedValueOnce(mockResponse(204, ''));

      await keycloak.assignRealmRole(VALID_UUID, 'docs-user');

      const postCall = global.fetch.mock.calls[2];
      expect(postCall[0]).toContain('/role-mappings/realm');
      expect(postCall[1].method).toBe('POST');
      const body = JSON.parse(postCall[1].body);
      expect(body).toEqual([role]);
    });

    it('throws when role is not found', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(404, 'Not Found'));

      await expect(keycloak.assignRealmRole(VALID_UUID, 'nonexistent'))
        .rejects.toThrow("Role 'nonexistent' not found: 404");
    });

    it('throws when POST role mapping fails', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, { id: 'r', name: 'role' }))
        .mockResolvedValueOnce(mockResponse(500, 'Internal Server Error'));

      await expect(keycloak.assignRealmRole(VALID_UUID, 'role'))
        .rejects.toThrow("Failed to assign role 'role'");
    });

    it('throws on invalid user ID', async () => {
      await expect(keycloak.assignRealmRole('bad', 'role'))
        .rejects.toThrow('Invalid user ID format');
    });
  });

  // ---- removeRealmRole ----

  describe('removeRealmRole', () => {
    it('fetches role and removes it from user', async () => {
      const role = { id: 'role-id', name: 'docs-user' };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, role))
        .mockResolvedValueOnce(mockResponse(204, ''));

      await keycloak.removeRealmRole(VALID_UUID, 'docs-user');

      const deleteCall = global.fetch.mock.calls[2];
      expect(deleteCall[0]).toContain('/role-mappings/realm');
      expect(deleteCall[1].method).toBe('DELETE');
    });

    it('silently returns when role does not exist (404)', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(404, 'Not Found'));

      await keycloak.removeRealmRole(VALID_UUID, 'nonexistent');
    });

    it('throws when role fetch fails with non-404 error', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(500, 'error'));

      await expect(keycloak.removeRealmRole(VALID_UUID, 'role'))
        .rejects.toThrow("Failed to get role 'role': 500");
    });

    it('throws on invalid user ID', async () => {
      await expect(keycloak.removeRealmRole('invalid', 'role'))
        .rejects.toThrow('Invalid user ID format');
    });
  });

  // ---- initiateAccountRecovery ----

  describe('initiateAccountRecovery', () => {
    const tenantEmail = 'alice@example.com';
    const recoveryEmail = 'alice.backup@gmail.com';

    let restoreNodemailer;

    beforeEach(() => {
      // Mock nodemailer for recovery tests (sendNotificationEmail uses it)
      const path = require.resolve('nodemailer');
      require('nodemailer');
      const original = require.cache[path].exports;
      require.cache[path].exports = {
        createTransport: () => ({
          sendMail: jest.fn().mockResolvedValue({}),
        }),
      };
      restoreNodemailer = () => {
        if (require.cache[path]) require.cache[path].exports = original;
      };
    });

    afterEach(() => {
      restoreNodemailer();
    });

    it('validates both emails and sends recovery email', async () => {
      const user = {
        id: VALID_UUID,
        email: tenantEmail,
        username: tenantEmail,
        attributes: {
          recoveryEmail: [recoveryEmail],
        },
      };

      global.fetch
        // getServiceToken (for findUserByEmail)
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        // findUserByEmail primary search
        .mockResolvedValueOnce(mockResponse(200, [user]))
        // GET credentials
        .mockResolvedValueOnce(mockResponse(200, []))
        // PUT user (swap email)
        .mockResolvedValueOnce(mockResponse(204, ''))
        // GET updated user
        .mockResolvedValueOnce(mockResponse(200, { ...user, email: recoveryEmail }))
        // PUT ensure required actions
        .mockResolvedValueOnce(mockResponse(204, ''))
        // PUT execute-actions-email
        .mockResolvedValueOnce(mockResponse(200, ''));

      const result = await keycloak.initiateAccountRecovery({
        tenantEmail, recoveryEmail,
      });

      expect(result.success).toBe(true);
      expect(result.message).toContain('Recovery link sent');
      expect(result.recoveryEmailHint).toMatch(/al\*\*\*@gm.*/);
    });

    it('throws when no user found', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, []))
        .mockResolvedValueOnce(mockResponse(200, []));

      await expect(keycloak.initiateAccountRecovery({
        tenantEmail, recoveryEmail,
      })).rejects.toThrow('No account found with that email address');
    });

    it('throws when recovery email is not configured', async () => {
      const user = { id: VALID_UUID, email: tenantEmail, attributes: {} };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [user]));

      await expect(keycloak.initiateAccountRecovery({
        tenantEmail, recoveryEmail,
      })).rejects.toThrow('does not have a recovery email configured');
    });

    it('throws when recovery email does not match', async () => {
      const user = {
        id: VALID_UUID,
        email: tenantEmail,
        attributes: { recoveryEmail: ['different@gmail.com'] },
      };

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [user]));

      await expect(keycloak.initiateAccountRecovery({
        tenantEmail, recoveryEmail,
      })).rejects.toThrow('recovery email address does not match');
    });

    it('removes existing webauthn credentials before recovery', async () => {
      const user = {
        id: VALID_UUID,
        email: tenantEmail,
        attributes: { recoveryEmail: [recoveryEmail] },
      };
      const credentials = [
        { id: 'cred-1', type: 'webauthn-passwordless' },
        { id: 'cred-2', type: 'webauthn' },
        { id: 'cred-3', type: 'password' },
      ];

      const deletedUrls = [];

      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(200, [user]))
        // GET credentials
        .mockResolvedValueOnce(mockResponse(200, credentials))
        // DELETE cred-1
        .mockImplementationOnce(async (url) => { deletedUrls.push(url); return mockResponse(204, ''); })
        // DELETE cred-2
        .mockImplementationOnce(async (url) => { deletedUrls.push(url); return mockResponse(204, ''); })
        // PUT user (swap)
        .mockResolvedValueOnce(mockResponse(204, ''))
        // GET updated user
        .mockResolvedValueOnce(mockResponse(200, { ...user, email: recoveryEmail }))
        // PUT ensure actions
        .mockResolvedValueOnce(mockResponse(204, ''))
        // PUT execute-actions-email
        .mockResolvedValueOnce(mockResponse(200, ''));

      await keycloak.initiateAccountRecovery({ tenantEmail, recoveryEmail });

      expect(deletedUrls).toHaveLength(2);
      expect(deletedUrls[0]).toContain('cred-1');
      expect(deletedUrls[1]).toContain('cred-2');
    });
  });

  // ---- createGuestUser ----

  describe('createGuestUser', () => {
    const guestEmail = 'guest@gmail.com';
    const guestParams = {
      email: guestEmail,
      firstName: 'Guest',
      lastName: 'User',
      redirectUri: 'https://account.test.example.com/guest-complete?doc=abc',
    };

    it('creates a guest user with correct attributes and roles', async () => {
      const createdUser = {
        id: VALID_UUID,
        email: guestEmail,
        attributes: {},
      };

      global.fetch
        // 1. getServiceToken
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        // 2. POST create user (201 with Location header)
        .mockResolvedValueOnce(mockResponse(201, '', {
          'Location': `http://keycloak.test/admin/realms/test-realm/users/${VALID_UUID}`,
        }))
        // 3. GET user (persist userType)
        .mockResolvedValueOnce(mockResponse(200, createdUser))
        // 4. PUT user (set userType)
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 5. assignRealmRole GET role 'guest-user' (token is cached)
        .mockResolvedValueOnce(mockResponse(200, { id: 'r1', name: 'guest-user' }))
        // 6. assignRealmRole POST mapping
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 7. removeRealmRole GET role 'docs-user' (token is cached)
        .mockResolvedValueOnce(mockResponse(200, { id: 'r2', name: 'docs-user' }))
        // 8. removeRealmRole DELETE mapping
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 9. PUT execute-actions-email
        .mockResolvedValueOnce(mockResponse(200, ''));

      const result = await keycloak.createGuestUser(guestParams);
      expect(result).toEqual({ userId: VALID_UUID });

      // Verify the POST body for user creation
      const createCall = global.fetch.mock.calls[1];
      const createBody = JSON.parse(createCall[1].body);
      expect(createBody.username).toBe(guestEmail);
      expect(createBody.email).toBe(guestEmail);
      expect(createBody.attributes.userType).toEqual(['guest']);
      expect(createBody.requiredActions).toContain('VERIFY_EMAIL');
      expect(createBody.requiredActions).toContain('webauthn-register-passwordless');
    });

    it('throws when user already exists (409)', async () => {
      global.fetch
        // getServiceToken
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        // POST create user returns 409
        .mockResolvedValueOnce(mockResponse(409, 'Conflict'));

      await expect(keycloak.createGuestUser(guestParams))
        .rejects.toThrow('A user with this email already exists');
    });

    it('throws on non-409 creation failure', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        .mockResolvedValueOnce(mockResponse(500, 'Server Error'));

      await expect(keycloak.createGuestUser(guestParams))
        .rejects.toThrow('Failed to create guest user');
    });

    it('falls back to search when Location header is missing', async () => {
      const createdUser = { id: VALID_UUID, email: guestEmail, attributes: {} };

      global.fetch
        // 1. getServiceToken
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        // 2. POST create (no Location header)
        .mockResolvedValueOnce(mockResponse(201, ''))
        // 3. Search by username (fallback)
        .mockResolvedValueOnce(mockResponse(200, [createdUser]))
        // 4. GET user for userType update
        .mockResolvedValueOnce(mockResponse(200, createdUser))
        // 5. PUT userType
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 6-7. assignRealmRole
        .mockResolvedValueOnce(mockResponse(200, { id: 'r1', name: 'guest-user' }))
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 8-9. removeRealmRole
        .mockResolvedValueOnce(mockResponse(200, { id: 'r2', name: 'docs-user' }))
        .mockResolvedValueOnce(mockResponse(204, ''))
        // 10. execute-actions-email
        .mockResolvedValueOnce(mockResponse(200, ''));

      const result = await keycloak.createGuestUser(guestParams);
      expect(result.userId).toBe(VALID_UUID);
    });
  });

  // ---- getServiceToken caching ----

  describe('getServiceToken caching', () => {
    it('caches the token and reuses it within expiry window', async () => {
      global.fetch
        // getServiceToken (only called once)
        .mockResolvedValueOnce(mockResponse(200, TOKEN_RESPONSE))
        // findUserByEmail #1: primary search returns user (no fallback needed)
        .mockResolvedValueOnce(mockResponse(200, [{ id: '1', email: 'a@b.com' }]))
        // findUserByEmail #2: primary search returns user (no fallback needed)
        .mockResolvedValueOnce(mockResponse(200, [{ id: '2', email: 'c@d.com' }]));

      await keycloak.findUserByEmail('a@b.com');
      await keycloak.findUserByEmail('c@d.com');

      // 1 token + 1 search + 1 search = 3 total calls
      expect(global.fetch).toHaveBeenCalledTimes(3);
      // First call is to token endpoint
      expect(global.fetch.mock.calls[0][0]).toContain('/protocol/openid-connect/token');
      // Second call is NOT to token endpoint (cached)
      expect(global.fetch.mock.calls[1][0]).not.toContain('/protocol/openid-connect/token');
      // Third call is NOT to token endpoint (cached)
      expect(global.fetch.mock.calls[2][0]).not.toContain('/protocol/openid-connect/token');
    });
  });
});
