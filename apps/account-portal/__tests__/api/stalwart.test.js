/**
 * Tests for api/stalwart.js — Stalwart v1 JMAP management API client
 *
 * Mocks global fetch(); each mocked response is a JMAP response envelope
 * ({ methodResponses: [[name, args, callId], ...] }) in request order.
 */

process.env.STALWART_API_URL = 'http://stalwart.test:8080';
process.env.STALWART_ADMIN_PASSWORD = 'test-admin-pass';

function httpResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

function jmapResponse(...methodResponses) {
  return httpResponse(200, { methodResponses, sessionState: 's1' });
}

/** Mock response for the account lookup (query by name + back-referenced get). */
function lookupResponse(accounts) {
  return jmapResponse(
    ['x:Account/query', { ids: accounts.map((a) => a.id) }, 'q'],
    ['x:Account/get', { list: accounts, notFound: [] }, 'g'],
  );
}

const ALICE = { id: 'c', name: 'alice', emailAddress: 'alice@example.com' };

describe('stalwart.js', () => {
  let stalwart;
  let originalFetch;

  function sentCalls(n) {
    return JSON.parse(global.fetch.mock.calls[n][1].body).methodCalls;
  }

  beforeEach(() => {
    originalFetch = global.fetch;
    global.fetch = jest.fn();
    jest.resetModules();
    stalwart = require('../../api/stalwart');
    jest.spyOn(console, 'log').mockImplementation(() => {});
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    global.fetch = originalFetch;
    jest.restoreAllMocks();
  });

  describe('JMAP transport', () => {
    it('POSTs to /jmap/ with admin Basic auth and the stalwart capability', async () => {
      global.fetch.mockResolvedValueOnce(lookupResponse([]));

      await stalwart.listAppPasswords('alice@example.com');

      const [url, opts] = global.fetch.mock.calls[0];
      expect(url).toBe('http://stalwart.test:8080/jmap/');
      expect(opts.method).toBe('POST');
      expect(opts.headers.Authorization).toBe('Basic ' + Buffer.from('admin:test-admin-pass').toString('base64'));
      expect(JSON.parse(opts.body).using).toEqual(['urn:ietf:params:jmap:core', 'urn:stalwart:jmap']);
    });

    it('throws on non-2xx HTTP status', async () => {
      global.fetch.mockResolvedValueOnce(httpResponse(401, 'Unauthorized'));

      await expect(stalwart.listAppPasswords('alice@example.com'))
        .rejects.toThrow('Stalwart JMAP request failed: 401');
    });

    it('throws a meaningful error on a method-level error response', async () => {
      global.fetch.mockResolvedValueOnce(jmapResponse(['error', { type: 'unknownMethod', description: 'x:Account/query' }, 'q']));

      await expect(stalwart.listAppPasswords('alice@example.com'))
        .rejects.toThrow('Stalwart x:Account/query failed: unknownMethod - x:Account/query');
    });
  });

  describe('ensureUserExists', () => {
    it('returns { created: false } when user already exists', async () => {
      global.fetch.mockResolvedValueOnce(lookupResponse([ALICE]));

      const result = await stalwart.ensureUserExists('Alice@Example.com', 'Alice', 5368709120);

      expect(result).toEqual({ created: false });
      expect(global.fetch).toHaveBeenCalledTimes(1);
      expect(sentCalls(0)[0]).toEqual(['x:Account/query', { filter: { name: 'alice' } }, 'q']);
    });

    it('creates user when they do not exist', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']))
        .mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']))
        .mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r1' } } }, 'r']));

      const result = await stalwart.ensureUserExists('alice@example.com', 'Alice Smith', 5368709120);

      expect(result).toEqual({ created: true });
      expect(global.fetch).toHaveBeenCalledTimes(4);
      expect(sentCalls(1)).toEqual([['x:Domain/query', { filter: { name: 'example.com' } }, 'd']]);
      expect(sentCalls(2)[0][1].create.n).toEqual({
        '@type': 'User',
        name: 'alice',
        domainId: 'b',
        description: 'Alice Smith',
        quotas: { maxDiskQuota: 5368709120 },
      });
      expect(sentCalls(3)).toEqual([['x:Action/set', { create: { r: { '@type': 'ReloadSettings' } } }, 'r']]);
    });

    it('creates user without quota when not specified, with empty description', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']))
        .mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']))
        .mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r1' } } }, 'r']));

      await stalwart.ensureUserExists('alice@example.com', undefined);

      const created = sentCalls(2)[0][1].create.n;
      expect(created.quotas).toBeUndefined();
      expect(created.description).toBe('');
    });

    it('returns { created: false } on primaryKeyViolation', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']))
        .mockResolvedValueOnce(jmapResponse(['x:Account/set', {
          notCreated: { n: { type: 'primaryKeyViolation', properties: ['email'] } },
        }, 'c']));

      const result = await stalwart.ensureUserExists('alice@example.com', 'Alice');
      expect(result).toEqual({ created: false });
    });

    it('throws on any other notCreated error', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']))
        .mockResolvedValueOnce(jmapResponse(['x:Account/set', {
          notCreated: { n: { type: 'invalidProperties', description: 'Invalid server hostname' } },
        }, 'c']));

      await expect(stalwart.ensureUserExists('alice@example.com', 'Alice'))
        .rejects.toThrow('Stalwart account creation failed for alice@example.com: invalidProperties - Invalid server hostname');
    });

    it('throws when the domain is not configured', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: [] }, 'd']));

      await expect(stalwart.ensureUserExists('alice@example.com', 'Alice'))
        .rejects.toThrow('Stalwart domain "example.com" not configured');
    });

    it('does not fail when the reload fails', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([]))
        .mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']))
        .mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']))
        .mockResolvedValueOnce(jmapResponse(['error', { type: 'forbidden' }, 'r']));

      const result = await stalwart.ensureUserExists('alice@example.com', 'Alice');
      expect(result).toEqual({ created: true });
      expect(console.warn).toHaveBeenCalledWith(expect.stringContaining('config reload failed (non-fatal)'));
    });
  });

  describe('listAppPasswords', () => {
    it('returns app password names (descriptions) without secrets', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', {
          accountId: 'c',
          list: [
            { id: 'p1', description: 'iPhone', secret: '****' },
            { id: 'p2', description: 'Thunderbird', secret: '****' },
          ],
        }, 'a']));

      const result = await stalwart.listAppPasswords('alice@example.com');

      expect(result).toEqual([{ name: 'iPhone' }, { name: 'Thunderbird' }]);
      expect(sentCalls(1)).toEqual([['x:AppPassword/get', { accountId: 'c' }, 'a']]);
    });

    it('returns empty array when the account does not exist', async () => {
      global.fetch.mockResolvedValueOnce(lookupResponse([]));

      expect(await stalwart.listAppPasswords('alice@example.com')).toEqual([]);
      expect(global.fetch).toHaveBeenCalledTimes(1);
    });

    it('ignores a same-name account in another domain', async () => {
      global.fetch.mockResolvedValueOnce(lookupResponse([{ ...ALICE, emailAddress: 'alice@other.org' }]));

      expect(await stalwart.listAppPasswords('alice@example.com')).toEqual([]);
    });

    it('returns empty array when no app passwords exist', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [] }, 'a']));

      expect(await stalwart.listAppPasswords('alice@example.com')).toEqual([]);
    });
  });

  describe('createAppPassword', () => {
    it('creates via x:AppPassword/set and returns the server-generated secret', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', {
          accountId: 'c', created: { a: { id: 'p1', secret: 'app_abc123' } },
        }, 'p']));

      const result = await stalwart.createAppPassword('alice@example.com', 'iPhone');

      expect(result).toEqual({ success: true, password: 'app_abc123' });
      expect(sentCalls(1)).toEqual([['x:AppPassword/set', { accountId: 'c', create: { a: { description: 'iPhone' } } }, 'p']]);
    });

    it('throws on notCreated', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { notCreated: { a: { type: 'invalidProperties', properties: ['description'] } } }, 'p']));

      await expect(stalwart.createAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Stalwart app password creation for alice@example.com failed (a): invalidProperties [description]');
    });

    it('throws when the server returns no secret', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { created: { a: { id: 'p1' } } }, 'p']));

      await expect(stalwart.createAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('returned no secret');
    });

    it('throws when the account does not exist', async () => {
      global.fetch.mockResolvedValueOnce(lookupResponse([]));

      await expect(stalwart.createAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Stalwart account for alice@example.com not found');
    });
  });

  describe('revokeAppPassword', () => {
    it('destroys the app passwords with the given name', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', {
          list: [{ id: 'p1', description: 'iPhone' }, { id: 'p2', description: 'Laptop' }],
        }, 'a']))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { destroyed: ['p1'] }, 'r']));

      const result = await stalwart.revokeAppPassword('alice@example.com', 'iPhone');

      expect(result).toEqual({ success: true });
      expect(sentCalls(2)).toEqual([['x:AppPassword/set', { accountId: 'c', destroy: ['p1'] }, 'r']]);
    });

    it('throws when app password name is not found', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [{ id: 'p2', description: 'Laptop' }] }, 'a']));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('App password "iPhone" not found');
    });

    it('throws when the lookup fails', async () => {
      global.fetch.mockResolvedValueOnce(httpResponse(500, 'Internal Server Error'));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Stalwart JMAP request failed: 500');
    });

    it('throws on notDestroyed', async () => {
      global.fetch
        .mockResolvedValueOnce(lookupResponse([ALICE]))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [{ id: 'p1', description: 'iPhone' }] }, 'a']))
        .mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { notDestroyed: { p1: { type: 'forbidden' } } }, 'r']));

      await expect(stalwart.revokeAppPassword('alice@example.com', 'iPhone'))
        .rejects.toThrow('Stalwart app password revoke for alice@example.com failed (p1): forbidden');
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
