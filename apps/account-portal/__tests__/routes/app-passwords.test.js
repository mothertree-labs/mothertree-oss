/**
 * Tests for app-passwords routes
 */

const request = require('supertest');
const { createTestApp } = require('./test-app');

const mockUser = {
  id: '550e8400-e29b-41d4-a716-446655440000',
  email: 'alice@example.com',
  name: 'Alice',
};

describe('GET /api/app-passwords', () => {
  it('returns list of app passwords when authenticated', async () => {
    const mockStalwartApi = {
      listAppPasswords: jest.fn().mockResolvedValue([
        { name: 'iPhone' },
        { name: 'Thunderbird' },
      ]),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app).get('/api/app-passwords');

    expect(res.status).toBe(200);
    expect(res.body).toEqual([
      { name: 'iPhone' },
      { name: 'Thunderbird' },
    ]);
    expect(mockStalwartApi.listAppPasswords).toHaveBeenCalledWith('alice@example.com');
  });

  it('returns 500 on stalwart API error', async () => {
    const mockStalwartApi = {
      listAppPasswords: jest.fn().mockRejectedValue(new Error('Connection refused')),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app).get('/api/app-passwords');

    expect(res.status).toBe(500);
    expect(res.body.error).toContain('Connection refused');
  });

  it('redirects when not authenticated', async () => {
    const app = createTestApp();
    const res = await request(app).get('/api/app-passwords');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/');
  });
});

describe('POST /api/app-passwords', () => {
  it('creates app password with valid request', async () => {
    const mockStalwartApi = {
      ensureUserExists: jest.fn().mockResolvedValue({ created: false }),
      createAppPassword: jest.fn().mockResolvedValue({ success: true }),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .post('/api/app-passwords')
      .set('Origin', 'https://account.example.com')
      .send({ deviceName: 'iPhone' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.password).toBeDefined();
    expect(typeof res.body.password).toBe('string');
    expect(res.body.password.length).toBeGreaterThan(0);

    expect(mockStalwartApi.ensureUserExists).toHaveBeenCalledWith(
      'alice@example.com', 'Alice', expect.any(Number)
    );
    expect(mockStalwartApi.createAppPassword).toHaveBeenCalledWith(
      'alice@example.com', 'iPhone', expect.any(String)
    );
  });

  it('returns 400 when deviceName is missing', async () => {
    const mockStalwartApi = {};
    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .post('/api/app-passwords')
      .set('Origin', 'https://account.example.com')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Device name is required');
  });

  it('returns 403 when Origin is missing (CSRF protection)', async () => {
    const mockStalwartApi = {};
    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .post('/api/app-passwords')
      .send({ deviceName: 'iPhone' });

    expect(res.status).toBe(403);
    expect(res.body.error).toBe('Forbidden');
  });

  it('returns 403 when Origin is from wrong domain', async () => {
    const mockStalwartApi = {};
    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .post('/api/app-passwords')
      .set('Origin', 'https://evil.com')
      .send({ deviceName: 'iPhone' });

    expect(res.status).toBe(403);
  });

  it('returns 500 on stalwart API error during creation', async () => {
    const mockStalwartApi = {
      ensureUserExists: jest.fn().mockResolvedValue({ created: false }),
      createAppPassword: jest.fn().mockRejectedValue(new Error('Stalwart error')),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .post('/api/app-passwords')
      .set('Origin', 'https://account.example.com')
      .send({ deviceName: 'Test' });

    expect(res.status).toBe(500);
    expect(res.body.error).toContain('Stalwart error');
  });
});

describe('DELETE /api/app-passwords/:name', () => {
  it('revokes app password with valid request', async () => {
    const mockStalwartApi = {
      revokeAppPassword: jest.fn().mockResolvedValue({ success: true }),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .delete('/api/app-passwords/iPhone')
      .set('Origin', 'https://account.example.com');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true });
    expect(mockStalwartApi.revokeAppPassword).toHaveBeenCalledWith('alice@example.com', 'iPhone');
  });

  it('returns 403 when Origin is missing (CSRF)', async () => {
    const mockStalwartApi = {};
    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app).delete('/api/app-passwords/iPhone');

    expect(res.status).toBe(403);
  });

  it('returns 500 on revoke error', async () => {
    const mockStalwartApi = {
      revokeAppPassword: jest.fn().mockRejectedValue(new Error('Not found')),
    };

    const app = createTestApp({ mockUser, mockStalwartApi });
    const res = await request(app)
      .delete('/api/app-passwords/iPhone')
      .set('Origin', 'https://account.example.com');

    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Failed to revoke app password');
  });
});
