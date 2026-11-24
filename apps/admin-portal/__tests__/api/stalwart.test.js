/**
 * Tests for api/stalwart.js — Stalwart v1 JMAP management API client
 *
 * global.fetch is mocked; each mocked response is a JMAP response envelope
 * ({ methodResponses: [[name, args, callId], ...] }) in the order the client
 * sends requests.
 */

process.env.STALWART_API_URL = 'http://stalwart.test';
process.env.STALWART_ADMIN_PASSWORD = 'admin-secret';

const STALWART_URL = process.env.STALWART_API_URL;

let fetchMock;

beforeEach(() => {
  fetchMock = jest.fn();
  global.fetch = fetchMock;
  jest.resetModules();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
});

function getStalwart() {
  return require('../../api/stalwart');
}

function httpResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

/** A JMAP response envelope. */
function jmapResponse(...methodResponses) {
  return httpResponse({ methodResponses, sessionState: 's1' });
}

/** Mock response for findAccount(): query by name + back-referenced get. */
function lookupResponse(accounts) {
  return jmapResponse(
    ['x:Account/query', { ids: accounts.map((a) => a.id) }, 'q'],
    ['x:Account/get', { list: accounts, notFound: [] }, 'g'],
  );
}

const ALICE = {
  id: 'c',
  '@type': 'User',
  name: 'alice',
  emailAddress: 'alice@test.com',
  description: 'Alice',
  quotas: { maxDiskQuota: 1073741824 },
  usedDiskQuota: 0,
};

/** Parsed JMAP methodCalls of the n-th fetch call. */
function sentCalls(n) {
  return JSON.parse(fetchMock.mock.calls[n][1].body).methodCalls;
}

// --- transport ---

describe('JMAP transport', () => {
  test('POSTs to /jmap/ with admin Basic auth and the stalwart capability', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));

    await stalwart.getUserQuota('alice@test.com');

    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe(`${STALWART_URL}/jmap/`);
    expect(opts.method).toBe('POST');
    expect(opts.headers.Authorization).toBe('Basic ' + Buffer.from('admin:admin-secret').toString('base64'));
    const body = JSON.parse(opts.body);
    expect(body.using).toEqual(['urn:ietf:params:jmap:core', 'urn:stalwart:jmap']);
  });

  test('throws on non-2xx HTTP status (e.g. bad credentials)', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(httpResponse('Unauthorized', 401));

    await expect(stalwart.getUserQuota('alice@test.com'))
      .rejects.toThrow('Stalwart JMAP request failed: 401');
  });

  test('throws a meaningful error on a method-level error response', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(jmapResponse(
      ['error', { type: 'forbidden', description: 'The server is in bootstrap mode.' }, 'q'],
    ));

    await expect(stalwart.getUserQuota('alice@test.com'))
      .rejects.toThrow('Stalwart x:Account/query failed: forbidden - The server is in bootstrap mode.');
  });

  test('throws when a method response is missing', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/query', { ids: [] }, 'q']));

    await expect(stalwart.getUserQuota('alice@test.com'))
      .rejects.toThrow('no response for call "g"');
  });

  test('throws when Stalwart API is not configured', async () => {
    const savedUrl = process.env.STALWART_API_URL;
    const savedPw = process.env.STALWART_ADMIN_PASSWORD;
    delete process.env.STALWART_API_URL;
    delete process.env.STALWART_ADMIN_PASSWORD;
    try {
      jest.resetModules();
      const stalwart = require('../../api/stalwart');
      await expect(stalwart.ensureUserExists('x@x.com', 'X', 0))
        .rejects.toThrow('Stalwart API not configured');
    } finally {
      process.env.STALWART_API_URL = savedUrl;
      process.env.STALWART_ADMIN_PASSWORD = savedPw;
    }
  });
});

// --- ensureUserExists ---

describe('ensureUserExists', () => {
  test('returns created:false when user already exists', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));

    const result = await stalwart.ensureUserExists('Alice@Test.com', 'Alice', 5368709120);

    expect(result.created).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const calls = sentCalls(0);
    expect(calls[0]).toEqual(['x:Account/query', { filter: { name: 'alice' } }, 'q']);
    expect(calls[1][0]).toBe('x:Account/get');
    expect(calls[1][1]['#ids']).toEqual({ resultOf: 'q', name: 'x:Account/query', path: '/ids' });
  });

  test('does not treat a same-name account in another domain as a match', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([{ ...ALICE, emailAddress: 'alice@other.com' }]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'z' } } }, 'c']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r1' } } }, 'r']));

    const result = await stalwart.ensureUserExists('alice@test.com', 'Alice', 0);
    expect(result.created).toBe(true);
  });

  test('creates user when not found and returns created:true', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r1' } } }, 'r']));

    const result = await stalwart.ensureUserExists('new@test.com', 'New User', 1073741824);

    expect(result.created).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(4);

    expect(sentCalls(1)).toEqual([['x:Domain/query', { filter: { name: 'test.com' } }, 'd']]);

    const [method, args] = sentCalls(2)[0];
    expect(method).toBe('x:Account/set');
    expect(args.create.n).toEqual({
      '@type': 'User',
      name: 'new',
      domainId: 'b',
      description: 'New User',
      quotas: { maxDiskQuota: 1073741824 },
    });

    expect(sentCalls(3)).toEqual([['x:Action/set', { create: { r: { '@type': 'ReloadSettings' } } }, 'r']]);
  });

  test('caches the domain id across creates', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r1' } } }, 'r']));
    await stalwart.ensureUserExists('one@test.com', 'One', 0);

    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'd' } } }, 'c']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r2' } } }, 'r']));
    const result = await stalwart.ensureUserExists('two@test.com', 'Two', 0);

    expect(result.created).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(7);
    expect(sentCalls(5)[0][0]).toBe('x:Account/set');
  });

  test('throws when the domain is not configured in Stalwart', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: [] }, 'd']));

    await expect(stalwart.ensureUserExists('new@missing.com', 'New', 0))
      .rejects.toThrow('Stalwart domain "missing.com" not configured');
  });

  test('returns created:false on primaryKeyViolation (concurrent create)', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', {
      notCreated: { n: { type: 'primaryKeyViolation', properties: ['email'] } },
    }, 'c']));

    const result = await stalwart.ensureUserExists('race@test.com', 'Race', 0);
    expect(result.created).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  test('throws on any other notCreated error', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', {
      notCreated: { n: { type: 'invalidProperties', description: 'Invalid value', properties: ['quotas'] } },
    }, 'c']));

    await expect(stalwart.ensureUserExists('bad@test.com', 'Bad', 5))
      .rejects.toThrow('Stalwart account creation failed for bad@test.com: invalidProperties - Invalid value [quotas]');
  });

  test('throws on a method-level error during create', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['error', { type: 'forbidden' }, 'c']));

    await expect(stalwart.ensureUserExists('new@test.com', 'New', 0))
      .rejects.toThrow('Stalwart x:Account/set failed: forbidden');
  });

  test('omits quotas when quotaBytes is 0/falsy and uses empty description', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Action/set', { created: { r: { id: 'r' } } }, 'r']));

    await stalwart.ensureUserExists('noquota@test.com', undefined, 0);

    const created = sentCalls(2)[0][1].create.n;
    expect(created.quotas).toBeUndefined();
    expect(created.description).toBe('');
  });

  test('a failing reload does not fail the invite', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Domain/query', { ids: ['b'] }, 'd']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { created: { n: { id: 'c' } } }, 'c']));
    fetchMock.mockRejectedValueOnce(new Error('connection reset'));

    const result = await stalwart.ensureUserExists('new@test.com', 'New', 0);
    expect(result.created).toBe(true);
    expect(console.warn).toHaveBeenCalledWith(expect.stringContaining('config reload failed (non-fatal)'));
  });

  test('retries the lookup once after a timeout', async () => {
    const stalwart = getStalwart();
    const timeout = Object.assign(new Error('The operation was aborted due to timeout'), { name: 'TimeoutError' });
    fetchMock.mockRejectedValueOnce(timeout);
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));

    const result = await stalwart.ensureUserExists('alice@test.com', 'Alice', 0);
    expect(result.created).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test('rejects an invalid email address', async () => {
    const stalwart = getStalwart();
    await expect(stalwart.ensureUserExists('not-an-email', 'X', 0))
      .rejects.toThrow('Invalid email address');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// --- ensureRoles ---

describe('ensureRoles', () => {
  test('is a no-op in Stalwart v1 (accounts default to the User role)', async () => {
    const stalwart = getStalwart();
    await expect(stalwart.ensureRoles('alice@test.com')).resolves.toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

// --- getUserQuota ---

describe('getUserQuota', () => {
  test('returns maxDiskQuota from the account', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));

    const result = await stalwart.getUserQuota('alice@test.com');
    expect(result).toEqual({ quota: 1073741824 });
  });

  test('returns quota 0 when the account does not exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));

    expect(await stalwart.getUserQuota('nobody@test.com')).toEqual({ quota: 0 });
  });

  test('returns quota 0 when no disk quota is set', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([{ ...ALICE, quotas: {} }]));

    expect(await stalwart.getUserQuota('alice@test.com')).toEqual({ quota: 0 });
  });
});

// --- getAllQuotas ---

describe('getAllQuotas', () => {
  function listResponse(accounts, total = accounts.length) {
    return jmapResponse(
      ['x:Account/query', { ids: accounts.map((a) => a.id), total }, 'q'],
      ['x:Account/get', { list: accounts }, 'g'],
    );
  }

  test('returns a lowercased email->quota map from a single request', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(listResponse([
      { id: 'a', '@type': 'User', name: 'alice', emailAddress: 'Alice@Example.com', quotas: { maxDiskQuota: 1073741824 } },
      { id: 'b', '@type': 'User', name: 'bob', emailAddress: 'bob@example.com', quotas: {} },
      { id: 'g', '@type': 'Group', name: 'team', emailAddress: 'team@example.com', quotas: { maxDiskQuota: 5 } },
    ]));

    const map = await stalwart.getAllQuotas();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const calls = sentCalls(0);
    expect(calls[0][0]).toBe('x:Account/query');
    expect(calls[0][1]).toMatchObject({ position: 0, limit: 500, calculateTotal: true });
    expect(map.get('alice@example.com')).toBe(1073741824);
    expect(map.get('bob@example.com')).toBe(0);
    expect(map.has('team@example.com')).toBe(false);
  });

  test('pages through more than 500 accounts', async () => {
    const stalwart = getStalwart();
    const page1 = Array.from({ length: 500 }, (_, i) => ({ id: `a${i}`, '@type': 'User', name: `u${i}`, emailAddress: `u${i}@x.com`, quotas: {} }));
    const page2 = [{ id: 'last', '@type': 'User', name: 'last', emailAddress: 'last@x.com', quotas: { maxDiskQuota: 7 } }];
    fetchMock.mockResolvedValueOnce(listResponse(page1, 501));
    fetchMock.mockResolvedValueOnce(listResponse(page2, 501));

    const map = await stalwart.getAllQuotas();

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(sentCalls(1)[0][1].position).toBe(500);
    expect(map.size).toBe(501);
    expect(map.get('last@x.com')).toBe(7);
  });

  test('throws when the list call fails', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(httpResponse('boom', 500));

    await expect(stalwart.getAllQuotas()).rejects.toThrow('Stalwart JMAP request failed: 500');
  });
});

// --- setUserQuota ---

describe('setUserQuota', () => {
  test('patches quotas/maxDiskQuota on the account', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { updated: { c: null } }, 'u']));

    const result = await stalwart.setUserQuota('alice@test.com', 2147483648);

    expect(result).toEqual({ success: true });
    expect(sentCalls(1)).toEqual([['x:Account/set', { update: { c: { 'quotas/maxDiskQuota': 2147483648 } } }, 'u']]);
  });

  test('removes the disk quota for 0 (unlimited)', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', { updated: { c: null } }, 'u']));

    await stalwart.setUserQuota('alice@test.com', 0);

    expect(sentCalls(1)[0][1].update.c).toEqual({ 'quotas/maxDiskQuota': null });
  });

  test('throws on notUpdated', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', {
      notUpdated: { c: { type: 'invalidPatch', description: 'Invalid value for object property', properties: ['quotas'] } },
    }, 'u']));

    await expect(stalwart.setUserQuota('alice@test.com', 5))
      .rejects.toThrow('Stalwart quota update for alice@test.com failed (c): invalidPatch - Invalid value for object property [quotas]');
  });

  test('throws when the account does not exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));

    await expect(stalwart.setUserQuota('nobody@test.com', 5))
      .rejects.toThrow('Stalwart account for nobody@test.com not found');
  });
});

// --- backfillQuotas ---

describe('backfillQuotas', () => {
  test('updates users without quotas in one set call, skipping admin, groups and set quotas', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(jmapResponse(
      ['x:Account/query', { ids: ['adm', 'u1', 'u2', 'u3', 'g'], total: 5 }, 'q'],
      ['x:Account/get', {
        list: [
          { id: 'adm', '@type': 'User', name: 'admin', emailAddress: 'admin@x.com', quotas: {} },
          { id: 'u1', '@type': 'User', name: 'u1', emailAddress: 'u1@x.com', quotas: {} },
          { id: 'u2', '@type': 'User', name: 'u2', emailAddress: 'u2@x.com', quotas: { maxDiskQuota: 10 } },
          { id: 'u3', '@type': 'User', name: 'u3', emailAddress: 'u3@x.com' },
          { id: 'g', '@type': 'Group', name: 'team', emailAddress: 'team@x.com', quotas: {} },
        ],
      }, 'g'],
    ));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:Account/set', {
      updated: { u1: null },
      notUpdated: { u3: { type: 'forbidden' } },
    }, 'u']));

    const result = await stalwart.backfillQuotas(5368709120);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(sentCalls(1)).toEqual([['x:Account/set', {
      update: {
        u1: { 'quotas/maxDiskQuota': 5368709120 },
        u3: { 'quotas/maxDiskQuota': 5368709120 },
      },
    }, 'u']]);
    expect(result).toEqual({ updated: 1, skipped: 4 });
  });

  test('makes no set call when nothing needs a quota', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(jmapResponse(
      ['x:Account/query', { ids: [], total: 0 }, 'q'],
      ['x:Account/get', { list: [] }, 'g'],
    ));

    expect(await stalwart.backfillQuotas(1)).toEqual({ updated: 0, skipped: 0 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('throws when list fails', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(httpResponse('Internal error', 500));

    await expect(stalwart.backfillQuotas(5368709120)).rejects.toThrow('Stalwart JMAP request failed: 500');
  });
});

// --- app passwords ---

describe('listAppPasswords', () => {
  test('returns names (descriptions) and never the secret', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', {
      accountId: 'c',
      list: [
        { id: 'p1', description: 'iPhone', secret: '****' },
        { id: 'p2', description: 'Thunderbird', secret: '****' },
      ],
    }, 'a']));

    const result = await stalwart.listAppPasswords('alice@test.com');

    expect(result).toEqual([{ name: 'iPhone' }, { name: 'Thunderbird' }]);
    expect(sentCalls(1)).toEqual([['x:AppPassword/get', { accountId: 'c' }, 'a']]);
  });

  test('returns empty array when the account does not exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));

    expect(await stalwart.listAppPasswords('nobody@test.com')).toEqual([]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test('returns empty array when no app passwords exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [] }, 'a']));

    expect(await stalwart.listAppPasswords('alice@test.com')).toEqual([]);
  });
});

describe('createAppPassword', () => {
  test('creates via x:AppPassword/set and returns the server-generated secret', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', {
      accountId: 'c', created: { a: { id: 'p1', secret: 'app_secret123' } },
    }, 'p']));

    const result = await stalwart.createAppPassword('alice@test.com', 'iPhone');

    expect(result).toEqual({ success: true, password: 'app_secret123' });
    expect(sentCalls(1)).toEqual([['x:AppPassword/set', { accountId: 'c', create: { a: { description: 'iPhone' } } }, 'p']]);
  });

  test('throws on notCreated', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', {
      notCreated: { a: { type: 'overQuota' } },
    }, 'p']));

    await expect(stalwart.createAppPassword('alice@test.com', 'iPhone'))
      .rejects.toThrow('Stalwart app password creation for alice@test.com failed (a): overQuota');
  });

  test('throws when the account does not exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));

    await expect(stalwart.createAppPassword('nobody@test.com', 'iPhone'))
      .rejects.toThrow('Stalwart account for nobody@test.com not found');
  });
});

describe('revokeAppPassword', () => {
  test('destroys every app password with the given name', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', {
      list: [
        { id: 'p1', description: 'iPhone' },
        { id: 'p2', description: 'Thunderbird' },
        { id: 'p3', description: 'iPhone' },
      ],
    }, 'a']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { destroyed: ['p1', 'p3'] }, 'r']));

    const result = await stalwart.revokeAppPassword('alice@test.com', 'iPhone');

    expect(result).toEqual({ success: true });
    expect(sentCalls(2)).toEqual([['x:AppPassword/set', { accountId: 'c', destroy: ['p1', 'p3'] }, 'r']]);
  });

  test('throws when app password name not found', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [{ id: 'p1', description: 'Other' }] }, 'a']));

    await expect(stalwart.revokeAppPassword('alice@test.com', 'iPhone'))
      .rejects.toThrow('App password "iPhone" not found');
  });

  test('throws on notDestroyed', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([ALICE]));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/get', { list: [{ id: 'p1', description: 'iPhone' }] }, 'a']));
    fetchMock.mockResolvedValueOnce(jmapResponse(['x:AppPassword/set', { notDestroyed: { p1: { type: 'notFound' } } }, 'r']));

    await expect(stalwart.revokeAppPassword('alice@test.com', 'iPhone'))
      .rejects.toThrow('Stalwart app password revoke for alice@test.com failed (p1): notFound');
  });

  test('throws when the account does not exist', async () => {
    const stalwart = getStalwart();
    fetchMock.mockResolvedValueOnce(lookupResponse([]));

    await expect(stalwart.revokeAppPassword('nobody@test.com', 'iPhone'))
      .rejects.toThrow('Stalwart account for nobody@test.com not found');
  });
});
