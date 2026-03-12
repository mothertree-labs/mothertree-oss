/**
 * Tests for api/keycloak.js — Keycloak Admin API client
 */

// Set env vars before requiring the module
process.env.KEYCLOAK_URL = 'http://keycloak.test';
process.env.KEYCLOAK_INTERNAL_URL = 'http://keycloak.test';
process.env.KEYCLOAK_REALM = 'test-realm';
process.env.KEYCLOAK_CLIENT_ID = 'test-client';
process.env.KEYCLOAK_CLIENT_SECRET = 'test-secret';
process.env.SESSION_SECRET = 'test-session-secret';
process.env.BEGINSETUP_SECRET = 'test-hmac-secret';
process.env.ACCOUNT_PORTAL_URL = 'https://account.test.example.com';
process.env.ACCOUNT_PORTAL_CLIENT_ID = 'account-portal';
process.env.STALWART_API_URL = 'http://stalwart.test';
process.env.STALWART_ADMIN_PASSWORD = 'stalwart-secret';
process.env.DEFAULT_EMAIL_QUOTA_MB = '5120';

const BASE = process.env.KEYCLOAK_URL;
const REALM = process.env.KEYCLOAK_REALM;

// We'll mock global fetch for all tests
let fetchMock;

beforeEach(() => {
  fetchMock = jest.fn();
  global.fetch = fetchMock;
  // Reset the cached token between tests by re-requiring the module
  jest.resetModules();
});

afterEach(() => {
  jest.restoreAllMocks();
});

function getKeycloak() {
  return require('../../api/keycloak');
}

// Helper to create mock Response objects
function mockResponse(body, options = {}) {
  const status = options.status || 200;
  const headers = new Map(Object.entries(options.headers || {}));
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (key) => headers.get(key) || null },
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

// --- getServiceToken ---

describe('getServiceToken', () => {
  test('fetches a new token from Keycloak', async () => {
    const keycloak = getKeycloak();
    fetchMock.mockResolvedValueOnce(mockResponse({
      access_token: 'tok-123',
      expires_in: 300,
    }));

    const token = await keycloak.__test__getServiceToken
      ? keycloak.__test__getServiceToken()
      : (await keycloak.createUser({ firstName: 'x', lastName: 'x', email: 'x@x.com', recoveryEmail: 'r@x.com' }).catch(() => null), null);

    // Since getServiceToken is not exported, we test it indirectly via createUser
    // Let's test createUser instead, which calls getServiceToken
  });

  test('caches token and reuses it within expiry window', async () => {
    const keycloak = getKeycloak();

    // First call: token endpoint
    fetchMock.mockResolvedValueOnce(mockResponse({
      access_token: 'tok-123',
      expires_in: 300,
    }));
    // createUser POST
    fetchMock.mockResolvedValueOnce(mockResponse(null, {
      status: 201,
      headers: { 'Location': `${BASE}/admin/realms/${REALM}/users/user-id-1` },
    }));
    // GET user for attribute update
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'user-id-1',
      email: 'test@example.com',
      attributes: {},
    }));
    // PUT user attributes
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    // GET user for verification
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'user-id-1',
      email: 'test@example.com',
      attributes: { recoveryEmail: ['r@example.com'], tenantEmail: ['test@example.com'] },
    }));
    // Stalwart ensureUserExists check
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    await keycloak.createUser({
      firstName: 'Test',
      lastName: 'User',
      email: 'test@example.com',
      recoveryEmail: 'r@example.com',
    });

    // Second call should reuse cached token (no new token request)
    // deleteUser makes just 1 fetch (DELETE)
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    await keycloak.deleteUser('12345678-1234-1234-1234-123456789abc');

    // The token endpoint should only have been called once
    const tokenCalls = fetchMock.mock.calls.filter(
      (call) => call[0].includes('protocol/openid-connect/token')
    );
    expect(tokenCalls).toHaveLength(1);
  });
});

// --- createUser ---

describe('createUser', () => {
  test('creates user and returns userId from Location header', async () => {
    const keycloak = getKeycloak();

    // getServiceToken
    fetchMock.mockResolvedValueOnce(mockResponse({
      access_token: 'tok-abc',
      expires_in: 300,
    }));
    // POST create user - 201 with Location header
    fetchMock.mockResolvedValueOnce(mockResponse(null, {
      status: 201,
      headers: { 'Location': `${BASE}/admin/realms/${REALM}/users/new-user-id` },
    }));
    // GET user for attribute update
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'new-user-id',
      email: 'alice@example.com',
      attributes: {},
    }));
    // PUT attributes
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    // GET verify
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'new-user-id',
      email: 'alice@example.com',
      attributes: { recoveryEmail: ['recovery@gmail.com'], tenantEmail: ['alice@example.com'] },
    }));
    // Stalwart ensureUserExists
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await keycloak.createUser({
      firstName: 'Alice',
      lastName: 'Smith',
      email: 'alice@example.com',
      recoveryEmail: 'recovery@gmail.com',
    });

    expect(result.userId).toBe('new-user-id');

    // Verify the POST body
    const createCall = fetchMock.mock.calls[1];
    const body = JSON.parse(createCall[1].body);
    expect(body.username).toBe('alice@example.com');
    expect(body.email).toBe('alice@example.com');
    expect(body.firstName).toBe('Alice');
    expect(body.enabled).toBe(true);
    expect(body.attributes.recoveryEmail).toEqual(['recovery@gmail.com']);
    expect(body.requiredActions).toEqual(['webauthn-register-passwordless']);
  });

  test('falls back to search when no Location header', async () => {
    const keycloak = getKeycloak();

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    // POST create user - 201 without Location header
    fetchMock.mockResolvedValueOnce(mockResponse(null, {
      status: 201,
      headers: {},
    }));
    // Search for user
    fetchMock.mockResolvedValueOnce(mockResponse([{ id: 'found-user-id' }]));
    // GET user for attributes
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'found-user-id',
      email: 'bob@example.com',
      attributes: {},
    }));
    // PUT attributes
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    // GET verify
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'found-user-id',
      email: 'bob@example.com',
      attributes: { recoveryEmail: ['r@gmail.com'], tenantEmail: ['bob@example.com'] },
    }));
    // Stalwart
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await keycloak.createUser({
      firstName: 'Bob',
      lastName: 'Jones',
      email: 'bob@example.com',
      recoveryEmail: 'r@gmail.com',
    });

    expect(result.userId).toBe('found-user-id');
  });

  test('throws on 409 duplicate user', async () => {
    const keycloak = getKeycloak();

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Conflict', { status: 409 }));

    await expect(keycloak.createUser({
      firstName: 'Dup',
      lastName: 'User',
      email: 'dup@example.com',
      recoveryEmail: 'r@test.com',
    })).rejects.toThrow('User already exists');
  });

  test('throws on other creation errors', async () => {
    const keycloak = getKeycloak();

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Server Error', { status: 500 }));

    await expect(keycloak.createUser({
      firstName: 'Err',
      lastName: 'User',
      email: 'err@example.com',
      recoveryEmail: 'r@test.com',
    })).rejects.toThrow('Failed to create user');
  });

  test('continues if Stalwart provisioning fails (non-fatal)', async () => {
    const keycloak = getKeycloak();

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse(null, {
      status: 201,
      headers: { 'Location': `${BASE}/admin/realms/${REALM}/users/user-stalwart-fail` },
    }));
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'user-stalwart-fail',
      email: 'sf@example.com',
      attributes: {},
    }));
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: 'user-stalwart-fail',
      email: 'sf@example.com',
      attributes: { recoveryEmail: ['r@test.com'], tenantEmail: ['sf@example.com'] },
    }));
    // Stalwart check fails
    fetchMock.mockResolvedValueOnce(mockResponse('Stalwart down', { status: 500 }));
    // Stalwart create also fails
    fetchMock.mockResolvedValueOnce(mockResponse('Stalwart down', { status: 500 }));

    // Should not throw despite Stalwart failure
    const result = await keycloak.createUser({
      firstName: 'SF',
      lastName: 'User',
      email: 'sf@example.com',
      recoveryEmail: 'r@test.com',
    });

    expect(result.userId).toBe('user-stalwart-fail');
  });
});

// --- sendInvitationEmail ---

describe('sendInvitationEmail', () => {
  test('swaps email to recovery and sends execute-actions-email', async () => {
    const keycloak = getKeycloak();
    const userId = '11111111-2222-3333-4444-555555555555';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    // GET user
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId,
      email: 'user@tenant.com',
      attributes: {
        tenantEmail: ['user@tenant.com'],
        recoveryEmail: ['user@gmail.com'],
      },
    }));
    // PUT update (swap email to recovery)
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));
    // PUT execute-actions-email
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));

    const result = await keycloak.sendInvitationEmail(userId);
    expect(result.success).toBe(true);

    // Verify the email was swapped to recovery email
    const updateCall = fetchMock.mock.calls[2];
    const updateBody = JSON.parse(updateCall[1].body);
    expect(updateBody.email).toBe('user@gmail.com');
    expect(updateBody.attributes.tenantEmail).toEqual(['user@tenant.com']);
    expect(updateBody.attributes.beginSetupToken).toBeDefined();

    // Verify execute-actions-email was sent
    const actionsCall = fetchMock.mock.calls[3];
    expect(actionsCall[0]).toContain('execute-actions-email');
    expect(actionsCall[0]).toContain('redirect_uri=');
    const actionsBody = JSON.parse(actionsCall[1].body);
    expect(actionsBody).toEqual(['webauthn-register-passwordless']);
  });

  test('throws when user has no recovery email', async () => {
    const keycloak = getKeycloak();
    const userId = '11111111-2222-3333-4444-555555555555';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId,
      email: 'user@tenant.com',
      attributes: {},
    }));

    await expect(keycloak.sendInvitationEmail(userId))
      .rejects.toThrow('User has no recovery email configured');
  });

  test('validates userId format', async () => {
    const keycloak = getKeycloak();

    await expect(keycloak.sendInvitationEmail('not-a-uuid'))
      .rejects.toThrow('Invalid user ID format');

    await expect(keycloak.sendInvitationEmail(''))
      .rejects.toThrow('Invalid user ID format');
  });
});

// --- listUsers ---

describe('listUsers', () => {
  test('returns enriched user list with passkey status', async () => {
    const keycloak = getKeycloak();
    const userId1 = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const userId2 = 'ffffffff-1111-2222-3333-444444444444';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    // GET users/count
    fetchMock.mockResolvedValueOnce(mockResponse(2));
    // GET users list
    fetchMock.mockResolvedValueOnce(mockResponse([
      {
        id: userId1,
        email: 'alice@example.com',
        firstName: 'Alice',
        lastName: 'Smith',
        enabled: true,
        createdTimestamp: 1700000000000,
        attributes: { recoveryEmail: ['alice.r@gmail.com'], userType: ['admin'] },
      },
      {
        id: userId2,
        email: 'bob@example.com',
        firstName: 'Bob',
        lastName: 'Jones',
        enabled: true,
        createdTimestamp: 1700000001000,
        attributes: { recoveryEmail: ['bob.r@gmail.com'] },
      },
    ]));
    // checkUserHasPasskey for user 1 - credentials call
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn-passwordless', id: 'cred-1' },
    ]));
    // checkUserHasPasskey for user 2 - no passkey
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'password', id: 'cred-2' },
    ]));
    // checkUserHasMagicLink for user 1 - GET user (no authMethod attribute)
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId1,
      attributes: { recoveryEmail: ['alice.r@gmail.com'], userType: ['admin'] },
    }));
    // checkUserHasMagicLink for user 2 - GET user (no authMethod attribute)
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId2,
      attributes: { recoveryEmail: ['bob.r@gmail.com'] },
    }));
    // checkUserHasMagicLink for user 1 - credentials check (no magic-link)
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn-passwordless', id: 'cred-1' },
    ]));
    // checkUserHasMagicLink for user 2 - credentials check (no magic-link)
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'password', id: 'cred-2' },
    ]));

    const users = await keycloak.listUsers();

    expect(users).toHaveLength(2);
    expect(users[0].email).toBe('alice@example.com');
    expect(users[0].hasPasskey).toBe(true);
    expect(users[0].hasMagicLink).toBe(false);
    expect(users[0].authMethod).toBe('passkey');
    expect(users[0].userType).toBe('admin');
    expect(users[1].email).toBe('bob@example.com');
    expect(users[1].hasPasskey).toBe(false);
    expect(users[1].hasMagicLink).toBe(false);
    expect(users[1].authMethod).toBe('none');
    expect(users[1].userType).toBe('member'); // default
  });
});

// --- checkUserHasPasskey ---

describe('checkUserHasPasskey', () => {
  test('returns true when webauthn-passwordless credential exists', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn-passwordless', id: 'pk-1' },
    ]));

    const result = await keycloak.checkUserHasPasskey(userId);
    expect(result).toBe(true);
  });

  test('returns true when webauthn credential exists', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn', id: 'pk-2' },
    ]));

    const result = await keycloak.checkUserHasPasskey(userId);
    expect(result).toBe(true);
  });

  test('returns false when no passkey credentials', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'password', id: 'pw-1' },
    ]));

    const result = await keycloak.checkUserHasPasskey(userId);
    expect(result).toBe(false);
  });

  test('returns false gracefully on API error', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));

    const result = await keycloak.checkUserHasPasskey(userId);
    expect(result).toBe(false);
  });

  test('rejects invalid userId format', async () => {
    const keycloak = getKeycloak();

    await expect(keycloak.checkUserHasPasskey('invalid'))
      .rejects.toThrow('Invalid user ID format');
  });
});

// --- ensurePasskeyFirst ---

describe('ensurePasskeyFirst', () => {
  test('moves passkey before password when password is first', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    // GET credentials - password first, then passkey
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'password', id: 'pw-1' },
      { type: 'webauthn-passwordless', id: 'pk-1' },
    ]));
    // POST moveToFirst
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));

    await keycloak.ensurePasskeyFirst(userId);

    // Verify moveToFirst was called with the passkey credential
    const moveCall = fetchMock.mock.calls[2];
    expect(moveCall[0]).toContain('pk-1/moveToFirst');
    expect(moveCall[1].method).toBe('POST');
  });

  test('does nothing when passkey is already first', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn-passwordless', id: 'pk-1' },
      { type: 'password', id: 'pw-1' },
    ]));

    await keycloak.ensurePasskeyFirst(userId);

    // Should only be 2 fetch calls (token + credentials), no moveToFirst
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test('does nothing when no passkey exists', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'password', id: 'pw-1' },
    ]));

    await keycloak.ensurePasskeyFirst(userId);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test('does nothing when no password exists', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse([
      { type: 'webauthn-passwordless', id: 'pk-1' },
    ]));

    await keycloak.ensurePasskeyFirst(userId);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

// --- deleteUser ---

describe('deleteUser', () => {
  test('deletes user successfully', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));

    const result = await keycloak.deleteUser(userId);
    expect(result.success).toBe(true);

    const deleteCall = fetchMock.mock.calls[1];
    expect(deleteCall[0]).toContain(`/users/${userId}`);
    expect(deleteCall[1].method).toBe('DELETE');
  });

  test('throws on API error', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));

    await expect(keycloak.deleteUser(userId))
      .rejects.toThrow('Failed to delete user: 404');
  });

  test('validates userId format', async () => {
    const keycloak = getKeycloak();

    await expect(keycloak.deleteUser('not-valid'))
      .rejects.toThrow('Invalid user ID format');

    await expect(keycloak.deleteUser(null))
      .rejects.toThrow('Invalid user ID format');
  });
});

// --- swapToTenantEmailIfNeeded ---

describe('swapToTenantEmailIfNeeded', () => {
  test('swaps email when tenantEmail differs from current email', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    // GET user - currently on recovery email
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId,
      email: 'recovery@gmail.com',
      username: 'recovery@gmail.com',
      attributes: { tenantEmail: ['user@tenant.com'] },
    }));
    // PUT update
    fetchMock.mockResolvedValueOnce(mockResponse(null, { status: 204 }));

    const result = await keycloak.swapToTenantEmailIfNeeded(userId);

    expect(result.swapped).toBe(true);
    expect(result.newEmail).toBe('user@tenant.com');

    const updateCall = fetchMock.mock.calls[2];
    const body = JSON.parse(updateCall[1].body);
    expect(body.email).toBe('user@tenant.com');
    expect(body.username).toBe('user@tenant.com');
    expect(body.attributes.isRecoveryFlow).toEqual([]);
  });

  test('does not swap when email already matches tenantEmail', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId,
      email: 'user@tenant.com',
      attributes: { tenantEmail: ['user@tenant.com'] },
    }));

    const result = await keycloak.swapToTenantEmailIfNeeded(userId);
    expect(result.swapped).toBe(false);
    // No PUT should have been called
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test('does not swap when no tenantEmail attribute', async () => {
    const keycloak = getKeycloak();
    const userId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

    fetchMock.mockResolvedValueOnce(mockResponse({ access_token: 'tok', expires_in: 300 }));
    fetchMock.mockResolvedValueOnce(mockResponse({
      id: userId,
      email: 'user@tenant.com',
      attributes: {},
    }));

    const result = await keycloak.swapToTenantEmailIfNeeded(userId);
    expect(result.swapped).toBe(false);
  });

  test('validates userId format', async () => {
    const keycloak = getKeycloak();

    await expect(keycloak.swapToTenantEmailIfNeeded('bad-id'))
      .rejects.toThrow('Invalid user ID format');
  });
});

// --- sendNotificationEmail ---

describe('sendNotificationEmail', () => {
  test('sends email via nodemailer and returns success', async () => {
    const keycloak = getKeycloak();

    // Mock nodemailer
    const mockSendMail = jest.fn().mockResolvedValue({ messageId: 'msg-1' });
    jest.doMock('nodemailer', () => ({
      createTransport: jest.fn(() => ({
        sendMail: mockSendMail,
      })),
    }));

    // Re-require to pick up the mock
    jest.resetModules();
    const keycloakWithMock = require('../../api/keycloak');

    const result = await keycloakWithMock.sendNotificationEmail(
      'user@example.com',
      'Test Subject',
      'Test message body'
    );

    expect(result.sent).toBe(true);
  });

  test('returns error on SMTP failure without throwing', async () => {
    jest.resetModules();

    jest.doMock('nodemailer', () => ({
      createTransport: jest.fn(() => ({
        sendMail: jest.fn().mockRejectedValue(new Error('SMTP connection refused')),
      })),
    }));

    const keycloakWithMock = require('../../api/keycloak');

    const result = await keycloakWithMock.sendNotificationEmail(
      'user@example.com',
      'Test Subject',
      'Test message body'
    );

    expect(result.sent).toBe(false);
    expect(result.error).toBe('SMTP connection refused');
  });
});
