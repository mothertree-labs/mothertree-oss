/**
 * Tests for guest registration routes
 */

const request = require('supertest');
const crypto = require('crypto');
const { createTestApp } = require('./test-app');

const VALID_UUID = '550e8400-e29b-41d4-a716-446655440000';

describe('POST /api/register-guest', () => {
  function makeMockKeycloakApi(overrides = {}) {
    return {
      findUserByEmail: jest.fn().mockResolvedValue(null),
      createGuestUser: jest.fn().mockResolvedValue({ userId: VALID_UUID }),
      initiateAccountRecovery: jest.fn(),
      ...overrides,
    };
  }

  it('creates a guest user with valid input', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({
        email: 'guest@gmail.com',
        firstName: 'Guest',
        lastName: 'User',
        doc: 'my-document',
      });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.userId).toBe(VALID_UUID);

    expect(mockKeycloakApi.findUserByEmail).toHaveBeenCalledWith('guest@gmail.com');
    expect(mockKeycloakApi.createGuestUser).toHaveBeenCalledWith({
      email: 'guest@gmail.com',
      firstName: 'Guest',
      lastName: 'User',
      redirectUri: expect.stringContaining('guest-complete?doc=my-document'),
    });
  });

  it('returns 400 when required fields are missing', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'guest@gmail.com' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('All fields are required');
  });

  it('returns 400 for invalid email format', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'not-an-email', firstName: 'A', lastName: 'B' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Invalid email address');
  });

  it('returns 400 when email is from tenant domain', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'alice@example.com', firstName: 'Alice', lastName: 'Smith' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('belongs to the organization');
  });

  it('returns 409 when user already exists', async () => {
    const mockKeycloakApi = makeMockKeycloakApi({
      findUserByEmail: jest.fn().mockResolvedValue({ id: 'existing-user' }),
    });
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'existing@gmail.com', firstName: 'A', lastName: 'B' });

    expect(res.status).toBe(409);
    expect(res.body.error).toContain('already exists');
  });

  it('returns 500 on guest creation failure', async () => {
    const mockKeycloakApi = makeMockKeycloakApi({
      createGuestUser: jest.fn().mockRejectedValue(new Error('Keycloak unavailable')),
    });
    const app = createTestApp({ mockKeycloakApi });

    const res = await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'guest@gmail.com', firstName: 'A', lastName: 'B' });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain('Keycloak unavailable');
  });

  it('returns 403 without Origin header (CSRF)', async () => {
    const app = createTestApp();
    const res = await request(app)
      .post('/api/register-guest')
      .send({ email: 'guest@gmail.com', firstName: 'A', lastName: 'B' });

    expect(res.status).toBe(403);
  });

  it('lowercases the email before processing', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'GUEST@Gmail.Com', firstName: 'A', lastName: 'B' });

    expect(mockKeycloakApi.findUserByEmail).toHaveBeenCalledWith('guest@gmail.com');
    expect(mockKeycloakApi.createGuestUser).toHaveBeenCalledWith(
      expect.objectContaining({ email: 'guest@gmail.com' })
    );
  });

  it('trims firstName and lastName', async () => {
    const mockKeycloakApi = makeMockKeycloakApi();
    const app = createTestApp({ mockKeycloakApi });

    await request(app)
      .post('/api/register-guest')
      .set('Origin', 'https://account.example.com')
      .send({ email: 'guest@gmail.com', firstName: '  Alice  ', lastName: '  Smith  ' });

    expect(mockKeycloakApi.createGuestUser).toHaveBeenCalledWith(
      expect.objectContaining({ firstName: 'Alice', lastName: 'Smith' })
    );
  });
});

describe('GET /guest-landing', () => {
  it('redirects to /register when email or doc is missing', async () => {
    const app = createTestApp();
    const res = await request(app).get('/guest-landing');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/register');
  });

  it('redirects to docs when user exists and is fully set up', async () => {
    const mockKeycloakApi = {
      findUserByEmail: jest.fn().mockResolvedValue({ id: 'user-1', requiredActions: [] }),
      initiateAccountRecovery: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .get('/guest-landing?email=alice@gmail.com&doc=test-doc');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('/docs/test-doc/');
  });

  it('renders guest-setup page when user exists but needs passkey setup', async () => {
    const mockKeycloakApi = {
      findUserByEmail: jest.fn().mockResolvedValue({
        id: 'user-1',
        requiredActions: ['VERIFY_EMAIL', 'webauthn-register-passwordless'],
      }),
      sendExecuteActionsEmail: jest.fn().mockResolvedValue(undefined),
      initiateAccountRecovery: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .get('/guest-landing?email=alice@gmail.com&share=abc123');

    expect(res.status).toBe(200);
    expect(res.text).toContain('Check your email');
    expect(res.text).toContain('al***@gm***.com');
    expect(mockKeycloakApi.sendExecuteActionsEmail).toHaveBeenCalledWith(
      'user-1',
      expect.stringContaining('guest-complete?share=abc123')
    );
  });

  it('redirects to files when user exists with share and no required actions', async () => {
    const mockKeycloakApi = {
      findUserByEmail: jest.fn().mockResolvedValue({ id: 'user-1', requiredActions: [] }),
      initiateAccountRecovery: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .get('/guest-landing?email=alice@gmail.com&share=abc123');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('/s/abc123');
  });

  it('redirects to /register when user does not exist', async () => {
    const mockKeycloakApi = {
      findUserByEmail: jest.fn().mockResolvedValue(null),
      initiateAccountRecovery: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .get('/guest-landing?email=new@gmail.com&doc=test-doc');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('/register?email=');
    expect(res.headers.location).toContain('new%40gmail.com');
    expect(res.headers.location).toContain('doc=test-doc');
  });

  it('falls through to register when lookup fails', async () => {
    const mockKeycloakApi = {
      findUserByEmail: jest.fn().mockRejectedValue(new Error('fail')),
      initiateAccountRecovery: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .get('/guest-landing?email=fail@gmail.com&doc=test-doc');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('/register?email=');
  });
});

describe('GET /beginSetup', () => {
  function generateBeginSetupToken(userId) {
    const secret = process.env.BEGINSETUP_SECRET || process.env.SESSION_SECRET;
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const hmac = crypto.createHmac('sha256', secret)
      .update(userId + ':' + timestamp)
      .digest('hex');
    return timestamp + ':' + hmac;
  }

  it('redirects to next URL with valid token', async () => {
    const app = createTestApp();
    const userId = VALID_UUID;
    const token = generateBeginSetupToken(userId);
    const nextUrl = 'https://auth.example.com/realms/test/login-actions/action-token?key=abc';

    const res = await request(app)
      .get(`/beginSetup?userId=${userId}&next=${encodeURIComponent(nextUrl)}&token=${token}`);

    expect(res.status).toBe(302);
    expect(res.headers.location).toBe(nextUrl);
  });

  it('returns 400 when userId is missing', async () => {
    const app = createTestApp();
    const res = await request(app).get('/beginSetup?next=https://example.com');
    expect(res.status).toBe(400);
    expect(res.text).toContain('Invalid setup link');
  });

  it('returns 400 when next is missing', async () => {
    const app = createTestApp();
    const res = await request(app).get(`/beginSetup?userId=${VALID_UUID}`);
    expect(res.status).toBe(400);
    expect(res.text).toContain('Invalid setup link');
  });

  it('returns 400 when redirect is to disallowed domain', async () => {
    const app = createTestApp();
    const userId = VALID_UUID;
    const token = generateBeginSetupToken(userId);
    const nextUrl = 'https://evil.com/steal-creds';

    const res = await request(app)
      .get(`/beginSetup?userId=${userId}&next=${encodeURIComponent(nextUrl)}&token=${token}`);

    expect(res.status).toBe(400);
    expect(res.text).toContain('Invalid redirect URL');
  });

  it('returns 403 when HMAC token is missing', async () => {
    const app = createTestApp();
    const nextUrl = 'https://auth.example.com/action';

    const res = await request(app)
      .get(`/beginSetup?userId=${VALID_UUID}&next=${encodeURIComponent(nextUrl)}`);

    expect(res.status).toBe(403);
    expect(res.text).toContain('Invalid or expired setup link');
  });

  it('returns 403 when HMAC token is invalid', async () => {
    const app = createTestApp();
    const nextUrl = 'https://auth.example.com/action';

    const res = await request(app)
      .get(`/beginSetup?userId=${VALID_UUID}&next=${encodeURIComponent(nextUrl)}&token=12345:${'a'.repeat(64)}`);

    expect(res.status).toBe(403);
  });

  it('returns 400 when next URL is not a valid URL', async () => {
    const app = createTestApp();
    const token = generateBeginSetupToken(VALID_UUID);
    const res = await request(app)
      .get(`/beginSetup?userId=${VALID_UUID}&next=not-a-url&token=${token}`);

    expect(res.status).toBe(400);
    expect(res.text).toContain('Invalid redirect URL');
  });
});

describe('GET /guest-complete', () => {
  it('redirects to docs host with doc parameter', async () => {
    const app = createTestApp();
    const res = await request(app).get('/guest-complete?doc=my-doc');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('/docs/my-doc/');
    expect(res.headers.location).toContain('docs.test.example.com');
  });

  it('redirects to docs host root without doc parameter', async () => {
    const app = createTestApp();
    const res = await request(app).get('/guest-complete');

    expect(res.status).toBe(302);
    expect(res.headers.location).toContain('docs.test.example.com');
  });
});
