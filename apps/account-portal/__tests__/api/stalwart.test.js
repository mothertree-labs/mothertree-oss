/**
 * Tests for api/stalwart.js
 *
 * Mocks global fetch() to simulate Stalwart Admin API responses.
 */

process.env.STALWART_API_URL = 'http://stalwart.test:8080';
process.env.STALWART_ADMIN_PASSWORD = 'test-admin-pass';

// Helper to create a mock fetch response
function mockResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

describe('stalwart.js', () => {
  let stalwart;
  let originalFetch;

  beforeEach(() => {
    originalFetch = global.fetch;
    global.fetch = jest.fn();
    delete require.cache[require.resolve('../../api/stalwart')];
    stalwart = require('../../api/stalwart');
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  describe('ensureUserExists', () => {
    it('returns { created: false } when user already exists', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, { data: { name: 'alice@example.com' } }));

      const result = await stalwart.ensureUserExists('alice@example.com', 'Alice', 5368709120);
      expect(result).toEqual({ created: false });

      // Check the auth header is Basic encoded
      const call = global.fetch.mock.calls[0];
      expect(call[0]).toContain('/api/principal/alice%40example.com');
      expect(call[1].headers['Authorization']).toMatch(/^Basic /);
    });

    it('creates user when they do not exist', async () => {
      global.fetch
        // Check user - 200 with {"error":"notFound"} (Stalwart returns 200 for all responses)
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'bob@example.com' }))
        // Create user - 200 (no error in body)
        .mockResolvedValueOnce(mockResponse(200, { data: { id: 1 } }))
        // Reload config (cache clear)
        .mockResolvedValueOnce(mockResponse(200, { data: {} }));

      const result = await stalwart.ensureUserExists('bob@example.com', 'Bob', 1073741824);
      expect(result).toEqual({ created: true });

      // Verify the POST body
      const createCall = global.fetch.mock.calls[1];
      expect(createCall[0]).toContain('/api/principal/deploy');
      expect(createCall[1].method).toBe('POST');
      const body = JSON.parse(createCall[1].body);
      expect(body.type).toBe('individual');
      expect(body.name).toBe('bob@example.com');
      expect(body.emails).toEqual(['bob@example.com']);
      expect(body.roles).toEqual(['user']);
      expect(body.quota).toBe(1073741824);
    });

    it('creates user without quota when not specified', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'user@example.com' }))
        .mockResolvedValueOnce(mockResponse(200, { data: { id: 2 } }))
        .mockResolvedValueOnce(mockResponse(200, { data: {} })); // reload

      await stalwart.ensureUserExists('user@example.com', 'User');

      const body = JSON.parse(global.fetch.mock.calls[1][1].body);
      expect(body.quota).toBeUndefined();
    });

    it('returns { created: false } on 409 conflict during creation', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'user@example.com' }))
        .mockResolvedValueOnce(mockResponse(409, 'Conflict'));

      const result = await stalwart.ensureUserExists('user@example.com', 'User');
      expect(result).toEqual({ created: false });
    });

    it('returns success when deploy returns fieldAlreadyExists', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'exists@example.com' }))
        .mockResolvedValueOnce(mockResponse(200, { error: 'fieldAlreadyExists' }));

      const result = await stalwart.ensureUserExists('exists@example.com', 'Existing User');
      expect(result.created).toBe(true);
    });

    it('returns success when deploy returns non-200 status', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'user@example.com' }))
        .mockResolvedValueOnce(mockResponse(500, 'Internal Server Error'));

      const result = await stalwart.ensureUserExists('user@example.com', 'User');
      expect(result.created).toBe(true);
    });

    it('uses empty string for description when name is not provided', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'user@example.com' }))
        .mockResolvedValueOnce(mockResponse(200, { data: { id: 3 } }))
        .mockResolvedValueOnce(mockResponse(200, { data: {} })); // reload

      await stalwart.ensureUserExists('user@example.com');

      const body = JSON.parse(global.fetch.mock.calls[1][1].body);
      expect(body.description).toBe('');
    });

    it('returns success when API returns unsupported error (OIDC directory mode)', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, { error: 'notFound', item: 'oidc@example.com' }))
        .mockResolvedValueOnce(mockResponse(200, {
          error: 'unsupported',
          details: 'OpenID directory cannot be managed.',
        }));

      const result = await stalwart.ensureUserExists('oidc@example.com', 'OIDC User', 0);
      expect(result.created).toBe(true);
    });
  });

  describe('listAppPasswords', () => {
    it('returns parsed app password names from secrets array', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, {
        data: {
          secrets: [
            '$app$iPhone$randompassword123',
            '$app$Thunderbird$anotherpassword456',
            'some-other-secret',
          ],
        },
      }));

      const result = await stalwart.listAppPasswords('alice@example.com');
      expect(result).toEqual([
        { name: 'iPhone' },
        { name: 'Thunderbird' },
      ]);
    });

    it('returns empty array when user not found (404)', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(404, 'Not Found'));

      const result = await stalwart.listAppPasswords('nobody@example.com');
      expect(result).toEqual([]);
    });

    it('returns empty array when no secrets exist', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, {
        data: { secrets: [] },
      }));

      const result = await stalwart.listAppPasswords('alice@example.com');
      expect(result).toEqual([]);
    });

    it('returns empty array when data.secrets is undefined', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, { data: {} }));

      const result = await stalwart.listAppPasswords('alice@example.com');
      expect(result).toEqual([]);
    });

    it('throws on non-404 error', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(500, 'Server Error'));

      await expect(stalwart.listAppPasswords('alice@example.com'))
        .rejects.toThrow('Failed to get principal: 500');
    });
  });

  describe('createAppPassword', () => {
    it('sends PATCH with addItem action for app password', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, ''));

      const result = await stalwart.createAppPassword(
        'alice@example.com', 'iPhone', 'securepassword123'
      );

      expect(result).toEqual({ success: true });

      const call = global.fetch.mock.calls[0];
      expect(call[1].method).toBe('PATCH');
      const body = JSON.parse(call[1].body);
      expect(body).toEqual([{
        action: 'addItem',
        field: 'secrets',
        value: '$app$iPhone$securepassword123',
      }]);
    });

    it('throws on failure', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(500, 'Server Error'));

      await expect(stalwart.createAppPassword('alice@example.com', 'Device', 'pass'))
        .rejects.toThrow('Failed to create app password: 500');
    });
  });

  describe('revokeAppPassword', () => {
    it('finds the full secret value and sends PATCH with removeItem', async () => {
      global.fetch
        // GET principal
        .mockResolvedValueOnce(mockResponse(200, {
          data: {
            secrets: [
              '$app$iPhone$randompass',
              '$app$Thunderbird$otherpass',
            ],
          },
        }))
        // PATCH remove
        .mockResolvedValueOnce(mockResponse(200, ''));

      const result = await stalwart.revokeAppPassword('alice@example.com', 'iPhone');
      expect(result).toEqual({ success: true });

      const patchCall = global.fetch.mock.calls[1];
      const body = JSON.parse(patchCall[1].body);
      expect(body).toEqual([{
        action: 'removeItem',
        field: 'secrets',
        value: '$app$iPhone$randompass',
      }]);
    });

    it('throws when app password name is not found', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(200, {
        data: {
          secrets: ['$app$Other$pass'],
        },
      }));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'NonExistent'))
        .rejects.toThrow('App password "NonExistent" not found');
    });

    it('throws when GET principal fails', async () => {
      global.fetch.mockResolvedValueOnce(mockResponse(500, 'Server Error'));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Failed to get principal: 500');
    });

    it('throws when PATCH remove fails', async () => {
      global.fetch
        .mockResolvedValueOnce(mockResponse(200, {
          data: { secrets: ['$app$iPhone$pass'] },
        }))
        .mockResolvedValueOnce(mockResponse(500, 'Error'));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Failed to revoke app password: 500');
    });
  });

  describe('getAdminAuth validation', () => {
    it('throws when STALWART_API_URL is not configured', async () => {
      const origUrl = process.env.STALWART_API_URL;
      const origFetch = global.fetch;
      try {
        delete process.env.STALWART_API_URL;
        // Must re-require with a clean fetch mock since module reads env at load time
        global.fetch = jest.fn();
        jest.resetModules();
        const freshStalwart = require('../../api/stalwart');

        await expect(freshStalwart.listAppPasswords('test@example.com'))
          .rejects.toThrow('Stalwart API not configured');
      } finally {
        process.env.STALWART_API_URL = origUrl;
        global.fetch = origFetch;
      }
    });

    it('throws when STALWART_ADMIN_PASSWORD is not configured', async () => {
      const origPass = process.env.STALWART_ADMIN_PASSWORD;
      const origFetch = global.fetch;
      try {
        delete process.env.STALWART_ADMIN_PASSWORD;
        global.fetch = jest.fn();
        jest.resetModules();
        const freshStalwart = require('../../api/stalwart');

        await expect(freshStalwart.listAppPasswords('test@example.com'))
          .rejects.toThrow('Stalwart API not configured');
      } finally {
        process.env.STALWART_ADMIN_PASSWORD = origPass;
        global.fetch = origFetch;
      }
    });
  });
});
