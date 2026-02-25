/**
 * Tests for recovery routes
 */

const request = require('supertest');
const { createTestApp } = require('./test-app');

describe('POST /recover', () => {
  it('renders error when emails are missing', async () => {
    const app = createTestApp();
    const res = await request(app)
      .post('/recover')
      .set('Origin', 'https://account.example.com')
      .send({});

    expect(res.status).toBe(200);
    expect(res.text).toContain('Both email addresses are required');
  });

  it('renders error when tenantEmail is missing', async () => {
    const app = createTestApp();
    const res = await request(app)
      .post('/recover')
      .set('Origin', 'https://account.example.com')
      .send({ recoveryEmail: 'backup@gmail.com' });

    expect(res.status).toBe(200);
    expect(res.text).toContain('Both email addresses are required');
  });

  it('renders success on valid recovery initiation', async () => {
    const mockKeycloakApi = {
      initiateAccountRecovery: jest.fn().mockResolvedValue({
        success: true,
        message: 'Recovery link sent to your recovery email address',
        recoveryEmailHint: 'ba***@gm***',
      }),
      findUserByEmail: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .post('/recover')
      .set('Origin', 'https://account.example.com')
      .send({
        tenantEmail: 'alice@example.com',
        recoveryEmail: 'backup@gmail.com',
      });

    expect(res.status).toBe(200);
    expect(res.text).toContain('Recovery Email Sent');

    expect(mockKeycloakApi.initiateAccountRecovery).toHaveBeenCalledWith({
      tenantEmail: 'alice@example.com',
      recoveryEmail: 'backup@gmail.com',
    });
  });

  it('trims and lowercases email inputs', async () => {
    const mockKeycloakApi = {
      initiateAccountRecovery: jest.fn().mockResolvedValue({
        success: true,
        message: 'Recovery link sent',
        recoveryEmailHint: 'ba***@gm***',
      }),
      findUserByEmail: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    await request(app)
      .post('/recover')
      .set('Origin', 'https://account.example.com')
      .send({
        tenantEmail: '  Alice@Example.COM  ',
        recoveryEmail: '  Backup@Gmail.COM  ',
      });

    expect(mockKeycloakApi.initiateAccountRecovery).toHaveBeenCalledWith({
      tenantEmail: 'alice@example.com',
      recoveryEmail: 'backup@gmail.com',
    });
  });

  it('renders error when recovery fails', async () => {
    const mockKeycloakApi = {
      initiateAccountRecovery: jest.fn().mockRejectedValue(
        new Error('No account found with that email address')
      ),
      findUserByEmail: jest.fn(),
      createGuestUser: jest.fn(),
    };

    const app = createTestApp({ mockKeycloakApi });
    const res = await request(app)
      .post('/recover')
      .set('Origin', 'https://account.example.com')
      .send({
        tenantEmail: 'nobody@example.com',
        recoveryEmail: 'backup@gmail.com',
      });

    expect(res.status).toBe(200);
    expect(res.text).toContain('No account found');
  });

  it('returns 403 without Origin header (CSRF)', async () => {
    const app = createTestApp();
    const res = await request(app)
      .post('/recover')
      .send({
        tenantEmail: 'alice@example.com',
        recoveryEmail: 'backup@gmail.com',
      });

    expect(res.status).toBe(403);
  });
});
