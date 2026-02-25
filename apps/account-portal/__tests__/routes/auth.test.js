/**
 * Tests for auth and health routes
 */

const request = require('supertest');
const { createTestApp } = require('./test-app');

describe('Health check', () => {
  it('GET /health returns 200 with { status: "ok" }', async () => {
    const app = createTestApp();
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});

describe('Home page', () => {
  it('GET / renders home page when unauthenticated', async () => {
    const app = createTestApp();
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.text).toContain('MotherTree Account');
  });

  it('GET / redirects to /app-passwords when authenticated', async () => {
    const app = createTestApp({
      mockUser: { id: 'user-1', email: 'alice@example.com', name: 'Alice' },
    });
    const res = await request(app).get('/');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/app-passwords');
  });
});

describe('Protected routes redirect when unauthenticated', () => {
  it('GET /app-passwords redirects to / when not authenticated', async () => {
    const app = createTestApp();
    const res = await request(app).get('/app-passwords');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/');
  });

  it('GET /api/app-passwords redirects to / when not authenticated', async () => {
    const app = createTestApp();
    const res = await request(app).get('/api/app-passwords');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('/');
  });
});

describe('Recovery page', () => {
  it('GET /recover renders recovery form', async () => {
    const app = createTestApp();
    const res = await request(app).get('/recover');
    expect(res.status).toBe(200);
    expect(res.text).toContain('Account Recovery');
  });
});

describe('Register page', () => {
  it('GET /register renders registration form', async () => {
    const app = createTestApp();
    const res = await request(app).get('/register');
    expect(res.status).toBe(200);
    expect(res.text).toContain('Guest Registration');
  });

  it('GET /register pre-fills email and masks it', async () => {
    const app = createTestApp();
    const res = await request(app).get('/register?email=alice@gmail.com&doc=testdoc');
    expect(res.status).toBe(200);
    expect(res.text).toContain('al***');
  });
});
