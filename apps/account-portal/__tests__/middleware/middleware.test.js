/**
 * Tests for middleware functions defined in server.js
 *
 * Since the middleware functions are defined inside server.js and not exported,
 * we test them through HTTP requests via supertest. The server.js module
 * requires OIDC initialization which we need to bypass for unit testing.
 *
 * Instead, we extract and test the middleware logic patterns directly.
 */

describe('verifyOrigin middleware', () => {
  // Re-implement the verifyOrigin logic for isolated testing
  // (it is not exported from server.js, so we test the pattern)
  const TENANT_DOMAIN = 'example.com';

  function verifyOrigin(origin, referer) {
    const source = origin || referer;
    if (!source) return false;
    try {
      const url = new URL(source);
      if (url.hostname !== TENANT_DOMAIN && !url.hostname.endsWith('.' + TENANT_DOMAIN)) {
        return false;
      }
      return true;
    } catch {
      return false;
    }
  }

  it('accepts requests from the tenant domain', () => {
    expect(verifyOrigin('https://example.com', null)).toBe(true);
  });

  it('accepts requests from subdomains of tenant domain', () => {
    expect(verifyOrigin('https://account.example.com', null)).toBe(true);
    expect(verifyOrigin('https://admin.example.com', null)).toBe(true);
    expect(verifyOrigin('https://docs.dev.example.com', null)).toBe(true);
  });

  it('rejects requests from other domains', () => {
    expect(verifyOrigin('https://evil.com', null)).toBe(false);
    expect(verifyOrigin('https://notexample.com', null)).toBe(false);
  });

  it('rejects requests with no Origin or Referer', () => {
    expect(verifyOrigin(null, null)).toBe(false);
    expect(verifyOrigin(undefined, undefined)).toBe(false);
  });

  it('uses Referer as fallback when Origin is missing', () => {
    expect(verifyOrigin(null, 'https://account.example.com/page')).toBe(true);
    expect(verifyOrigin(null, 'https://evil.com/page')).toBe(false);
  });

  it('rejects invalid URLs', () => {
    expect(verifyOrigin('not-a-url', null)).toBe(false);
  });
});

describe('requireAuth middleware', () => {
  // Re-implement the requireAuth logic for isolated testing
  function requireAuth(isAuthenticated) {
    if (isAuthenticated) return 'next';
    return 'redirect:/';
  }

  it('calls next when user is authenticated', () => {
    expect(requireAuth(true)).toBe('next');
  });

  it('redirects to / when user is not authenticated', () => {
    expect(requireAuth(false)).toBe('redirect:/');
  });
});

describe('verifyBeginSetupToken', () => {
  const crypto = require('crypto');
  const SECRET = 'test-secret';

  function generateBeginSetupToken(userId) {
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const hmac = crypto.createHmac('sha256', SECRET)
      .update(userId + ':' + timestamp)
      .digest('hex');
    return timestamp + ':' + hmac;
  }

  function verifyBeginSetupToken(userId, token) {
    if (!token) return false;
    const parts = token.split(':');
    if (parts.length !== 2) return false;
    const [timestamp, providedHmac] = parts;
    const age = Math.floor(Date.now() / 1000) - parseInt(timestamp, 10);
    if (isNaN(age) || age < 0 || age > 7 * 24 * 60 * 60) return false;
    const expectedHmac = crypto.createHmac('sha256', SECRET)
      .update(userId + ':' + timestamp)
      .digest('hex');
    return crypto.timingSafeEqual(Buffer.from(providedHmac, 'hex'), Buffer.from(expectedHmac, 'hex'));
  }

  it('validates a freshly generated token', () => {
    const userId = '550e8400-e29b-41d4-a716-446655440000';
    const token = generateBeginSetupToken(userId);
    expect(verifyBeginSetupToken(userId, token)).toBe(true);
  });

  it('rejects null token', () => {
    expect(verifyBeginSetupToken('user-id', null)).toBe(false);
  });

  it('rejects empty token', () => {
    expect(verifyBeginSetupToken('user-id', '')).toBe(false);
  });

  it('rejects token with wrong format', () => {
    expect(verifyBeginSetupToken('user-id', 'no-colon-here')).toBe(false);
    expect(verifyBeginSetupToken('user-id', 'a:b:c')).toBe(false);
  });

  it('rejects token for different user', () => {
    const token = generateBeginSetupToken('user-1');
    expect(verifyBeginSetupToken('user-2', token)).toBe(false);
  });

  it('rejects expired token (older than 7 days)', () => {
    const userId = 'test-user';
    const oldTimestamp = (Math.floor(Date.now() / 1000) - 8 * 24 * 60 * 60).toString();
    const hmac = crypto.createHmac('sha256', SECRET)
      .update(userId + ':' + oldTimestamp)
      .digest('hex');
    const token = oldTimestamp + ':' + hmac;
    expect(verifyBeginSetupToken(userId, token)).toBe(false);
  });

  it('rejects token with future timestamp', () => {
    const userId = 'test-user';
    const futureTimestamp = (Math.floor(Date.now() / 1000) + 3600).toString();
    const hmac = crypto.createHmac('sha256', SECRET)
      .update(userId + ':' + futureTimestamp)
      .digest('hex');
    const token = futureTimestamp + ':' + hmac;
    expect(verifyBeginSetupToken(userId, token)).toBe(false);
  });

  it('rejects token with tampered HMAC', () => {
    const userId = 'test-user';
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const tamperedHmac = 'a'.repeat(64); // Valid hex length but wrong value
    const token = timestamp + ':' + tamperedHmac;
    expect(verifyBeginSetupToken(userId, token)).toBe(false);
  });
});

describe('checkGuestRateLimit', () => {
  // Re-implement the rate limit logic for isolated testing
  function createRateLimiter(maxAttempts, windowMs) {
    const attempts = new Map();

    return function checkRateLimit(ip) {
      const now = Date.now();
      const existing = (attempts.get(ip) || []).filter(t => t > now - windowMs);
      attempts.set(ip, existing);
      if (existing.length >= maxAttempts) return false;
      existing.push(now);
      attempts.set(ip, existing);
      return true;
    };
  }

  it('allows requests under the limit', () => {
    const check = createRateLimiter(3, 60000);
    expect(check('1.2.3.4')).toBe(true);
    expect(check('1.2.3.4')).toBe(true);
    expect(check('1.2.3.4')).toBe(true);
  });

  it('blocks requests over the limit', () => {
    const check = createRateLimiter(2, 60000);
    expect(check('1.2.3.4')).toBe(true);
    expect(check('1.2.3.4')).toBe(true);
    expect(check('1.2.3.4')).toBe(false);
  });

  it('tracks IPs independently', () => {
    const check = createRateLimiter(1, 60000);
    expect(check('1.1.1.1')).toBe(true);
    expect(check('2.2.2.2')).toBe(true);
    expect(check('1.1.1.1')).toBe(false);
    expect(check('2.2.2.2')).toBe(false);
  });
});

describe('cookieDomain computation', () => {
  function computeCookieDomain(baseUrl) {
    try {
      const host = new URL(baseUrl).hostname;
      const parts = host.split('.');
      return parts.length > 2 ? '.' + parts.slice(1).join('.') : undefined;
    } catch { return undefined; }
  }

  it('strips first subdomain for shared cookie domain', () => {
    expect(computeCookieDomain('https://account.dev.example.com')).toBe('.dev.example.com');
  });

  it('strips first subdomain for production URL', () => {
    expect(computeCookieDomain('https://account.example.com')).toBe('.example.com');
  });

  it('returns undefined for two-part hostname', () => {
    expect(computeCookieDomain('https://example.com')).toBeUndefined();
  });

  it('returns undefined for invalid URL', () => {
    expect(computeCookieDomain('not-a-url')).toBeUndefined();
  });
});
