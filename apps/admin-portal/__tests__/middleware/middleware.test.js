/**
 * Tests for middleware functions defined in server.js:
 * - requireAuth
 * - requireTenantAdmin
 * - verifyOrigin
 *
 * These are extracted and tested independently without starting the full server.
 */

// We test the middleware logic directly without importing server.js (which has side effects).
// The middleware functions are simple enough to replicate from source for isolated testing.

describe('requireAuth', () => {
  function requireAuth(req, res, next) {
    if (req.isAuthenticated()) {
      return next();
    }
    res.redirect('/');
  }

  test('calls next() when user is authenticated', () => {
    const req = { isAuthenticated: () => true };
    const res = { redirect: jest.fn() };
    const next = jest.fn();

    requireAuth(req, res, next);

    expect(next).toHaveBeenCalled();
    expect(res.redirect).not.toHaveBeenCalled();
  });

  test('redirects to / when user is not authenticated', () => {
    const req = { isAuthenticated: () => false };
    const res = { redirect: jest.fn() };
    const next = jest.fn();

    requireAuth(req, res, next);

    expect(res.redirect).toHaveBeenCalledWith('/');
    expect(next).not.toHaveBeenCalled();
  });
});

describe('requireTenantAdmin', () => {
  function requireTenantAdmin(req, res, next) {
    if (req.isAuthenticated() && req.user.roles.includes('tenant-admin')) {
      return next();
    }
    res.status(403).render('error', {
      title: 'Access Denied',
      message: 'You need the tenant-admin role to access this page.'
    });
  }

  test('calls next() when user is authenticated and has tenant-admin role', () => {
    const req = {
      isAuthenticated: () => true,
      user: { roles: ['tenant-admin', 'user'] },
    };
    const res = { status: jest.fn().mockReturnThis(), render: jest.fn() };
    const next = jest.fn();

    requireTenantAdmin(req, res, next);

    expect(next).toHaveBeenCalled();
    expect(res.status).not.toHaveBeenCalled();
  });

  test('returns 403 when user lacks tenant-admin role', () => {
    const req = {
      isAuthenticated: () => true,
      user: { roles: ['user'] },
    };
    const res = { status: jest.fn().mockReturnThis(), render: jest.fn() };
    const next = jest.fn();

    requireTenantAdmin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.render).toHaveBeenCalledWith('error', expect.objectContaining({
      title: 'Access Denied',
    }));
  });

  test('returns 403 when user is not authenticated', () => {
    const req = {
      isAuthenticated: () => false,
      user: null,
    };
    const res = { status: jest.fn().mockReturnThis(), render: jest.fn() };
    const next = jest.fn();

    // This would throw if we don't handle the null user case
    // The actual code checks isAuthenticated first, so roles won't be accessed
    requireTenantAdmin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });
});

describe('verifyOrigin', () => {
  const TENANT_DOMAIN = 'example.com';

  function verifyOrigin(req, res, next) {
    const origin = req.get('Origin');
    const referer = req.get('Referer');
    const source = origin || referer;
    if (!source) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    try {
      const url = new URL(source);
      const domain = TENANT_DOMAIN;
      if (url.hostname !== domain && !url.hostname.endsWith('.' + domain)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
    } catch {
      return res.status(403).json({ error: 'Forbidden' });
    }
    next();
  }

  function makeReq(headers = {}) {
    return {
      get: (key) => headers[key] || null,
    };
  }

  function makeRes() {
    const res = {
      status: jest.fn().mockReturnThis(),
      json: jest.fn().mockReturnThis(),
    };
    return res;
  }

  test('passes when Origin matches tenant domain', () => {
    const req = makeReq({ Origin: 'https://example.com' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).toHaveBeenCalled();
    expect(res.status).not.toHaveBeenCalled();
  });

  test('passes when Origin is a subdomain of tenant domain', () => {
    const req = makeReq({ Origin: 'https://admin.example.com' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).toHaveBeenCalled();
  });

  test('passes when Referer matches (no Origin)', () => {
    const req = makeReq({ Referer: 'https://admin.example.com/dashboard' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).toHaveBeenCalled();
  });

  test('rejects when no Origin or Referer header', () => {
    const req = makeReq({});
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith({ error: 'Forbidden' });
  });

  test('rejects when Origin is from a different domain', () => {
    const req = makeReq({ Origin: 'https://evil.com' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });

  test('rejects when Origin is an invalid URL', () => {
    const req = makeReq({ Origin: 'not-a-url' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });

  test('rejects partial domain match (security check)', () => {
    // notexample.com should NOT match example.com
    const req = makeReq({ Origin: 'https://notexample.com' });
    const res = makeRes();
    const next = jest.fn();

    verifyOrigin(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });
});
