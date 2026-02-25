/**
 * Tests for api/stalwart.js — Stalwart Mail Server API client
 */

process.env.STALWART_API_URL = 'http://stalwart.test';
process.env.STALWART_ADMIN_PASSWORD = 'admin-secret';

const STALWART_URL = process.env.STALWART_API_URL;

let fetchMock;

beforeEach(() => {
  fetchMock = jest.fn();
  global.fetch = fetchMock;
  jest.resetModules();
});

afterEach(() => {
  jest.restoreAllMocks();
});

function getStalwart() {
  return require('../../api/stalwart');
}

function mockResponse(body, options = {}) {
  const status = options.status || 200;
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
  };
}

// --- ensureUserExists ---

describe('ensureUserExists', () => {
  test('returns created:false when user already exists', async () => {
    const stalwart = getStalwart();

    // Check user - 200 means exists
    fetchMock.mockResolvedValueOnce(mockResponse({ data: { name: 'user@test.com' } }));

    const result = await stalwart.ensureUserExists('user@test.com', 'Test User', 5368709120);

    expect(result.created).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toContain('/api/principal/user%40test.com');
  });

  test('creates user when not found and returns created:true', async () => {
    const stalwart = getStalwart();

    // Check user - 404
    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));
    // Create user - 200
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.ensureUserExists('new@test.com', 'New User', 1073741824);

    expect(result.created).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);

    const createCall = fetchMock.mock.calls[1];
    expect(createCall[0]).toBe(`${STALWART_URL}/api/principal`);
    expect(createCall[1].method).toBe('POST');

    const body = JSON.parse(createCall[1].body);
    expect(body.type).toBe('individual');
    expect(body.name).toBe('new@test.com');
    expect(body.emails).toEqual(['new@test.com']);
    expect(body.description).toBe('New User');
    expect(body.quota).toBe(1073741824);
  });

  test('returns created:false on 409 conflict (race condition)', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Conflict', { status: 409 }));

    const result = await stalwart.ensureUserExists('race@test.com', 'Race User', 0);
    expect(result.created).toBe(false);
  });

  test('throws on create failure (non-409)', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));
    fetchMock.mockResolvedValueOnce(mockResponse('Internal Error', { status: 500 }));

    await expect(stalwart.ensureUserExists('fail@test.com', 'Fail User', 0))
      .rejects.toThrow('Failed to create Stalwart principal: 500');
  });

  test('omits quota field when quotaBytes is 0/falsy', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    await stalwart.ensureUserExists('noq@test.com', 'No Quota', 0);

    const body = JSON.parse(fetchMock.mock.calls[1][1].body);
    expect(body.quota).toBeUndefined();
  });

  test('throws when Stalwart API is not configured', () => {
    // Temporarily unset env vars
    const savedUrl = process.env.STALWART_API_URL;
    const savedPw = process.env.STALWART_ADMIN_PASSWORD;
    delete process.env.STALWART_API_URL;
    delete process.env.STALWART_ADMIN_PASSWORD;

    jest.resetModules();
    const stalwart = require('../../api/stalwart');

    expect(() => stalwart.ensureUserExists('x@x.com', 'X', 0))
      .rejects.toThrow('Stalwart API not configured');

    // Restore
    process.env.STALWART_API_URL = savedUrl;
    process.env.STALWART_ADMIN_PASSWORD = savedPw;
  });
});

// --- getUserQuota ---

describe('getUserQuota', () => {
  test('returns quota from API response', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: { quota: 5368709120 } }));

    const result = await stalwart.getUserQuota('user@test.com');
    expect(result.quota).toBe(5368709120);
  });

  test('returns quota 0 for 404 (user not found)', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));

    const result = await stalwart.getUserQuota('missing@test.com');
    expect(result.quota).toBe(0);
  });

  test('returns quota 0 when quota field is missing', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.getUserQuota('nodata@test.com');
    expect(result.quota).toBe(0);
  });

  test('throws on non-404 API errors', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Server Error', { status: 500 }));

    await expect(stalwart.getUserQuota('err@test.com'))
      .rejects.toThrow('Failed to get principal: 500');
  });
});

// --- setUserQuota ---

describe('setUserQuota', () => {
  test('sends PATCH request with quota value', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.setUserQuota('user@test.com', 10737418240);

    expect(result.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);

    const call = fetchMock.mock.calls[0];
    expect(call[0]).toContain('/api/principal/user%40test.com');
    expect(call[1].method).toBe('PATCH');

    const body = JSON.parse(call[1].body);
    expect(body).toEqual([{ action: 'set', field: 'quota', value: 10737418240 }]);
  });

  test('sets quota to 0 for unlimited', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    await stalwart.setUserQuota('user@test.com', 0);

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body[0].value).toBe(0);
  });

  test('throws on API error', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));

    await expect(stalwart.setUserQuota('missing@test.com', 1024))
      .rejects.toThrow('Failed to set quota: 404');
  });
});

// --- backfillQuotas ---

describe('backfillQuotas', () => {
  test('updates users without quotas and skips admin', async () => {
    const stalwart = getStalwart();

    // List principals
    fetchMock.mockResolvedValueOnce(mockResponse({
      data: { items: ['admin', 'user1@test.com', 'user2@test.com'] },
    }));
    // GET user1 - no quota
    fetchMock.mockResolvedValueOnce(mockResponse({ data: { quota: 0 } }));
    // PATCH user1
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));
    // GET user2 - has quota
    fetchMock.mockResolvedValueOnce(mockResponse({ data: { quota: 5368709120 } }));

    const result = await stalwart.backfillQuotas(5368709120);

    expect(result.updated).toBe(1);
    expect(result.skipped).toBe(2); // admin + user2
  });

  test('handles object items with quota info', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({
      data: {
        items: [
          { name: 'admin', quota: 0 },
          { name: 'user1@test.com', quota: 0 },
          { name: 'user2@test.com', quota: 5368709120 },
        ],
      },
    }));
    // PATCH user1 (no quota)
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.backfillQuotas(5368709120);

    expect(result.updated).toBe(1);  // user1
    expect(result.skipped).toBe(2);  // admin + user2 (has quota)
  });

  test('throws when list fails', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Error', { status: 500 }));

    await expect(stalwart.backfillQuotas(5368709120))
      .rejects.toThrow('Failed to list principals: 500');
  });
});

// --- listAppPasswords ---

describe('listAppPasswords', () => {
  test('returns parsed app password names', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({
      data: {
        secrets: [
          '$app$Thunderbird$hashed-pw-1',
          '$app$iPhone$hashed-pw-2',
          'regular-secret',
        ],
      },
    }));

    const result = await stalwart.listAppPasswords('user@test.com');

    expect(result).toEqual([
      { name: 'Thunderbird' },
      { name: 'iPhone' },
    ]);
  });

  test('returns empty array for 404', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Not Found', { status: 404 }));

    const result = await stalwart.listAppPasswords('missing@test.com');
    expect(result).toEqual([]);
  });

  test('returns empty array when no app passwords exist', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({
      data: { secrets: ['regular-secret'] },
    }));

    const result = await stalwart.listAppPasswords('user@test.com');
    expect(result).toEqual([]);
  });

  test('handles missing secrets gracefully', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.listAppPasswords('user@test.com');
    expect(result).toEqual([]);
  });
});

// --- createAppPassword ---

describe('createAppPassword', () => {
  test('sends PATCH with addItem action', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.createAppPassword('user@test.com', 'Thunderbird', 'secret-pw');

    expect(result.success).toBe(true);

    const call = fetchMock.mock.calls[0];
    expect(call[1].method).toBe('PATCH');

    const body = JSON.parse(call[1].body);
    expect(body).toEqual([{
      action: 'addItem',
      field: 'secrets',
      value: '$app$Thunderbird$secret-pw',
    }]);
  });

  test('throws on API error', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Error', { status: 500 }));

    await expect(stalwart.createAppPassword('user@test.com', 'Device', 'pw'))
      .rejects.toThrow('Failed to create app password: 500');
  });
});

// --- revokeAppPassword ---

describe('revokeAppPassword', () => {
  test('finds and removes app password by name', async () => {
    const stalwart = getStalwart();

    // GET principal to find the full secret
    fetchMock.mockResolvedValueOnce(mockResponse({
      data: {
        secrets: [
          '$app$Thunderbird$hashed-pw-1',
          '$app$iPhone$hashed-pw-2',
        ],
      },
    }));
    // PATCH to remove
    fetchMock.mockResolvedValueOnce(mockResponse({ data: {} }));

    const result = await stalwart.revokeAppPassword('user@test.com', 'Thunderbird');

    expect(result.success).toBe(true);

    const patchBody = JSON.parse(fetchMock.mock.calls[1][1].body);
    expect(patchBody).toEqual([{
      action: 'removeItem',
      field: 'secrets',
      value: '$app$Thunderbird$hashed-pw-1',
    }]);
  });

  test('throws when app password name not found', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse({
      data: { secrets: ['$app$iPhone$hashed-pw-2'] },
    }));

    await expect(stalwart.revokeAppPassword('user@test.com', 'NonExistent'))
      .rejects.toThrow('App password "NonExistent" not found');
  });

  test('throws when get principal fails', async () => {
    const stalwart = getStalwart();

    fetchMock.mockResolvedValueOnce(mockResponse('Error', { status: 500 }));

    await expect(stalwart.revokeAppPassword('user@test.com', 'Device'))
      .rejects.toThrow('Failed to get principal: 500');
  });
});
