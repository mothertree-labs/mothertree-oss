/**
 * Route integration tests using supertest.
 *
 * We build a minimal Express app that mirrors the routes from server.js
 * but without OIDC, Redis, or other external dependencies.
 * This tests the route handlers, middleware chaining, and request/response contracts.
 */

const express = require('express');
const path = require('path');
const request = require('supertest');

// Mock the API modules
jest.mock('../../api/keycloak');
jest.mock('../../api/stalwart');

const keycloakApi = require('../../api/keycloak');
const stalwartApi = require('../../api/stalwart');

// --- Test app factory ---

function createTestApp({ authenticated = false, roles = [], user = null } = {}) {
  const app = express();
  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));

  app.set('view engine', 'ejs');
  app.set('views', path.join(__dirname, '../../views'));

  // Simulate authentication state
  app.use((req, res, next) => {
    req.isAuthenticated = () => authenticated;
    if (authenticated) {
      req.user = user || {
        id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        email: 'admin@example.com',
        name: 'Admin User',
        roles: roles,
      };
    }
    // Simulate req.get for origin verification
    const originalGet = req.get.bind(req);
    req.get = (header) => originalGet(header);
    next();
  });

  const TENANT_DOMAIN = 'example.com';

  // Middleware replicas from server.js
  function verifyOrigin(req, res, next) {
    const origin = req.get('Origin');
    const referer = req.get('Referer');
    const source = origin || referer;
    if (!source) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    try {
      const url = new URL(source);
      if (url.hostname !== TENANT_DOMAIN && !url.hostname.endsWith('.' + TENANT_DOMAIN)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
    } catch {
      return res.status(403).json({ error: 'Forbidden' });
    }
    next();
  }

  function requireAuth(req, res, next) {
    if (req.isAuthenticated()) return next();
    res.redirect('/');
  }

  function requireTenantAdmin(req, res, next) {
    if (req.isAuthenticated() && req.user.roles.includes('tenant-admin')) return next();
    res.status(403).render('error', {
      title: 'Access Denied',
      message: 'You need the tenant-admin role to access this page.',
    });
  }

  // Routes (matching server.js)
  app.get('/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  app.get('/', (req, res) => {
    if (req.isAuthenticated()) return res.redirect('/dashboard');
    res.render('home', { title: 'MotherTree Admin Portal' });
  });

  app.get('/dashboard', requireAuth, requireTenantAdmin, (req, res) => {
    res.render('dashboard', { title: 'Dashboard', user: req.user });
  });

  app.post('/api/invite', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
    try {
      const { firstName, lastName, email, recoveryEmail } = req.body;
      if (!firstName || !lastName || !email || !recoveryEmail) {
        return res.status(400).json({ error: 'All fields are required' });
      }
      const result = await keycloakApi.createUser({ firstName, lastName, email, recoveryEmail });
      await keycloakApi.sendInvitationEmail(result.userId);
      res.json({ success: true, userId: result.userId });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.get('/api/users', requireAuth, requireTenantAdmin, async (req, res) => {
    try {
      const users = await keycloakApi.listUsers();
      const enriched = await Promise.all(users.map(async (user) => {
        try {
          const { quota } = await stalwartApi.getUserQuota(user.email);
          user.quotaMb = quota > 0 ? Math.round(quota / (1024 * 1024)) : 0;
        } catch {
          user.quotaMb = 0;
        }
        return user;
      }));
      res.json(enriched);
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.delete('/api/users/:id', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
    try {
      await keycloakApi.deleteUser(req.params.id);
      res.json({ success: true });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.put('/api/users/:email/quota', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
    try {
      const { quotaMb } = req.body;
      if (quotaMb === undefined || quotaMb === null || quotaMb < 0) {
        return res.status(400).json({ error: 'quotaMb is required and must be >= 0' });
      }
      const quotaBytes = Math.round(quotaMb) * 1024 * 1024;
      await stalwartApi.setUserQuota(req.params.email, quotaBytes);
      res.json({ success: true });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.post('/api/quota/backfill', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
    try {
      const result = await stalwartApi.backfillQuotas(5368709120);
      res.json(result);
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  return app;
}

// --- Tests ---

beforeEach(() => {
  jest.clearAllMocks();
});

describe('GET /health', () => {
  test('returns 200 with status ok', async () => {
    const app = createTestApp();

    const res = await request(app).get('/health');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});

describe('GET / (home)', () => {
  test('renders home page for unauthenticated users', async () => {
    const app = createTestApp({ authenticated: false });

    const res = await request(app).get('/');

    expect(res.status).toBe(200);
    expect(res.text).toContain('MotherTree');
  });

  test('redirects authenticated users to /dashboard', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app).get('/');

    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/dashboard');
  });
});

describe('GET /dashboard', () => {
  test('redirects to / when unauthenticated', async () => {
    const app = createTestApp({ authenticated: false });

    const res = await request(app).get('/dashboard');

    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/');
  });

  test('returns 403 when missing tenant-admin role', async () => {
    const app = createTestApp({ authenticated: true, roles: ['user'] });

    const res = await request(app).get('/dashboard');

    expect(res.status).toBe(403);
  });

  test('renders dashboard for authenticated tenant-admin', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app).get('/dashboard');

    expect(res.status).toBe(200);
    expect(res.text).toContain('Dashboard');
  });
});

describe('POST /api/invite', () => {
  const validPayload = {
    firstName: 'Alice',
    lastName: 'Smith',
    email: 'alice@example.com',
    recoveryEmail: 'alice@gmail.com',
  };

  test('creates user and sends invitation with valid data', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.createUser.mockResolvedValue({ userId: 'new-user-id' });
    keycloakApi.sendInvitationEmail.mockResolvedValue({ success: true });

    const res = await request(app)
      .post('/api/invite')
      .set('Origin', 'https://admin.example.com')
      .send(validPayload);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.userId).toBe('new-user-id');

    expect(keycloakApi.createUser).toHaveBeenCalledWith(validPayload);
    expect(keycloakApi.sendInvitationEmail).toHaveBeenCalledWith('new-user-id');
  });

  test('returns 400 when fields are missing', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .post('/api/invite')
      .set('Origin', 'https://admin.example.com')
      .send({ firstName: 'Alice' });

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('All fields are required');
  });

  test('returns 500 when createUser fails', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.createUser.mockRejectedValue(new Error('User already exists'));

    const res = await request(app)
      .post('/api/invite')
      .set('Origin', 'https://admin.example.com')
      .send(validPayload);

    expect(res.status).toBe(500);
    expect(res.body.error).toBe('User already exists');
  });

  test('returns 403 without Origin header (CSRF)', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .post('/api/invite')
      .send(validPayload);

    expect(res.status).toBe(403);
  });

  test('redirects to / when unauthenticated', async () => {
    const app = createTestApp({ authenticated: false });

    const res = await request(app)
      .post('/api/invite')
      .set('Origin', 'https://admin.example.com')
      .send(validPayload);

    expect(res.status).toBe(302);
  });
});

describe('GET /api/users', () => {
  test('returns enriched user list', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.listUsers.mockResolvedValue([
      { id: 'u1', email: 'alice@example.com', firstName: 'Alice' },
      { id: 'u2', email: 'bob@example.com', firstName: 'Bob' },
    ]);
    stalwartApi.getUserQuota
      .mockResolvedValueOnce({ quota: 5368709120 })  // ~5120 MB
      .mockResolvedValueOnce({ quota: 0 });

    const res = await request(app).get('/api/users');

    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(2);
    expect(res.body[0].quotaMb).toBe(5120);
    expect(res.body[1].quotaMb).toBe(0);
  });

  test('returns 500 on listUsers error', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.listUsers.mockRejectedValue(new Error('Keycloak down'));

    const res = await request(app).get('/api/users');

    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Keycloak down');
  });

  test('handles quota fetch failure gracefully (sets 0)', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.listUsers.mockResolvedValue([
      { id: 'u1', email: 'alice@example.com' },
    ]);
    stalwartApi.getUserQuota.mockRejectedValue(new Error('Stalwart down'));

    const res = await request(app).get('/api/users');

    expect(res.status).toBe(200);
    expect(res.body[0].quotaMb).toBe(0);
  });
});

describe('DELETE /api/users/:id', () => {
  test('deletes user successfully', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.deleteUser.mockResolvedValue({ success: true });

    const res = await request(app)
      .delete('/api/users/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      .set('Origin', 'https://admin.example.com');

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(keycloakApi.deleteUser).toHaveBeenCalledWith('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
  });

  test('returns 403 without Origin header (CSRF protection)', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .delete('/api/users/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');

    expect(res.status).toBe(403);
  });

  test('returns 500 on deleteUser error', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    keycloakApi.deleteUser.mockRejectedValue(new Error('Failed to delete user: 404'));

    const res = await request(app)
      .delete('/api/users/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')
      .set('Origin', 'https://admin.example.com');

    expect(res.status).toBe(500);
    expect(res.body.error).toContain('Failed to delete user');
  });
});

describe('PUT /api/users/:email/quota', () => {
  test('sets user quota successfully', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    stalwartApi.setUserQuota.mockResolvedValue({ success: true });

    const res = await request(app)
      .put('/api/users/alice@example.com/quota')
      .set('Origin', 'https://admin.example.com')
      .send({ quotaMb: 10240 });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(stalwartApi.setUserQuota).toHaveBeenCalledWith('alice@example.com', 10240 * 1024 * 1024);
  });

  test('returns 400 when quotaMb is missing', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .put('/api/users/alice@example.com/quota')
      .set('Origin', 'https://admin.example.com')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.error).toContain('quotaMb is required');
  });

  test('returns 400 when quotaMb is negative', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .put('/api/users/alice@example.com/quota')
      .set('Origin', 'https://admin.example.com')
      .send({ quotaMb: -100 });

    expect(res.status).toBe(400);
  });

  test('allows quotaMb of 0 (unlimited)', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    stalwartApi.setUserQuota.mockResolvedValue({ success: true });

    const res = await request(app)
      .put('/api/users/alice@example.com/quota')
      .set('Origin', 'https://admin.example.com')
      .send({ quotaMb: 0 });

    expect(res.status).toBe(200);
    expect(stalwartApi.setUserQuota).toHaveBeenCalledWith('alice@example.com', 0);
  });

  test('returns 403 without Origin header', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    const res = await request(app)
      .put('/api/users/alice@example.com/quota')
      .send({ quotaMb: 100 });

    expect(res.status).toBe(403);
  });
});

describe('POST /api/quota/backfill', () => {
  test('runs backfill and returns results', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    stalwartApi.backfillQuotas.mockResolvedValue({ updated: 5, skipped: 2 });

    const res = await request(app)
      .post('/api/quota/backfill')
      .set('Origin', 'https://admin.example.com');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ updated: 5, skipped: 2 });
  });

  test('returns 500 on backfill error', async () => {
    const app = createTestApp({ authenticated: true, roles: ['tenant-admin'] });

    stalwartApi.backfillQuotas.mockRejectedValue(new Error('Stalwart down'));

    const res = await request(app)
      .post('/api/quota/backfill')
      .set('Origin', 'https://admin.example.com');

    expect(res.status).toBe(500);
    expect(res.body.error).toBe('Stalwart down');
  });
});

describe('protected routes redirect when unauthenticated', () => {
  test('GET /dashboard redirects', async () => {
    const app = createTestApp({ authenticated: false });
    const res = await request(app).get('/dashboard');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/');
  });

  test('GET /api/users redirects', async () => {
    const app = createTestApp({ authenticated: false });
    const res = await request(app).get('/api/users');
    expect(res.status).toBe(302);
  });

  test('POST /api/invite redirects', async () => {
    const app = createTestApp({ authenticated: false });
    const res = await request(app)
      .post('/api/invite')
      .set('Origin', 'https://admin.example.com')
      .send({ firstName: 'A', lastName: 'B', email: 'a@b.com', recoveryEmail: 'r@b.com' });
    expect(res.status).toBe(302);
  });
});
