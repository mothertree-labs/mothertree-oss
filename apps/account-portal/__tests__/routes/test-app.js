/**
 * Shared test app factory for route testing.
 *
 * Creates a minimal Express app that mirrors the routes and middleware
 * from server.js, but skips OIDC initialization, Redis, and Helmet
 * to allow isolated unit testing with supertest.
 */

const express = require('express');
const path = require('path');
const crypto = require('crypto');

// Environment needed for route logic
process.env.SESSION_SECRET = process.env.SESSION_SECRET || 'test-secret';
process.env.TENANT_DOMAIN = process.env.TENANT_DOMAIN || 'example.com';
process.env.BASE_URL = process.env.BASE_URL || 'https://account.test.example.com';
process.env.WEBMAIL_HOST = process.env.WEBMAIL_HOST || 'webmail.test.example.com';
process.env.KEYCLOAK_ISSUER = process.env.KEYCLOAK_ISSUER || 'https://auth.test.example.com/realms/test';
process.env.KEYCLOAK_URL = process.env.KEYCLOAK_URL || 'http://keycloak.test';
process.env.KEYCLOAK_REALM = process.env.KEYCLOAK_REALM || 'test-realm';
process.env.KEYCLOAK_CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID || 'test-client';
process.env.KEYCLOAK_CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET || 'test-secret';
process.env.STALWART_API_URL = process.env.STALWART_API_URL || 'http://stalwart.test:8080';
process.env.STALWART_ADMIN_PASSWORD = process.env.STALWART_ADMIN_PASSWORD || 'test-pass';
process.env.BEGINSETUP_SECRET = process.env.BEGINSETUP_SECRET || 'test-beginsetup-secret';

/**
 * Create a test Express app with optional mock user for authenticated routes.
 *
 * @param {object} [options]
 * @param {object} [options.mockUser] - Simulated authenticated user
 * @param {object} [options.mockKeycloakApi] - Mock keycloak API module
 * @param {object} [options.mockStalwartApi] - Mock stalwart API module
 */
function createTestApp(options = {}) {
  const app = express();

  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));

  // View engine (for routes that render)
  app.set('view engine', 'ejs');
  app.set('views', path.join(__dirname, '../../views'));

  // Policy URLs
  app.locals.privacyPolicyUrl = '';
  app.locals.termsOfUseUrl = '';
  app.locals.acceptableUsePolicyUrl = '';

  // Simulate authentication middleware
  app.use((req, res, next) => {
    if (options.mockUser) {
      req.isAuthenticated = () => true;
      req.user = options.mockUser;
    } else {
      req.isAuthenticated = () => false;
      req.user = null;
    }
    next();
  });

  // verifyOrigin middleware
  function verifyOrigin(req, res, next) {
    const origin = req.get('Origin');
    const referer = req.get('Referer');
    const source = origin || referer;
    if (!source) {
      return res.status(403).json({ error: 'Forbidden' });
    }
    try {
      const url = new URL(source);
      const domain = process.env.TENANT_DOMAIN;
      if (url.hostname !== domain && !url.hostname.endsWith('.' + domain)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
    } catch {
      return res.status(403).json({ error: 'Forbidden' });
    }
    next();
  }

  // requireAuth middleware
  function requireAuth(req, res, next) {
    if (req.isAuthenticated()) {
      return next();
    }
    res.redirect('/');
  }

  // beginSetup token verification
  const BEGINSETUP_SECRET = process.env.BEGINSETUP_SECRET || process.env.SESSION_SECRET;

  function verifyBeginSetupToken(userId, token) {
    if (!token) return false;
    const parts = token.split(':');
    if (parts.length !== 2) return false;
    const [timestamp, providedHmac] = parts;
    const age = Math.floor(Date.now() / 1000) - parseInt(timestamp, 10);
    if (isNaN(age) || age < 0 || age > 7 * 24 * 60 * 60) return false;
    const expectedHmac = crypto.createHmac('sha256', BEGINSETUP_SECRET)
      .update(userId + ':' + timestamp)
      .digest('hex');
    return crypto.timingSafeEqual(Buffer.from(providedHmac, 'hex'), Buffer.from(expectedHmac, 'hex'));
  }

  // beginSetup rate limiter
  const beginSetupAttempts = new Map();
  function checkBeginSetupRateLimit(ip) {
    const now = Date.now();
    const windowMs = 15 * 60 * 1000;
    const maxAttempts = 20;
    const attempts = (beginSetupAttempts.get(ip) || []).filter(t => t > now - windowMs);
    beginSetupAttempts.set(ip, attempts);
    if (attempts.length >= maxAttempts) return false;
    attempts.push(now);
    beginSetupAttempts.set(ip, attempts);
    return true;
  }

  // API modules (mocked or real)
  const stalwartApi = options.mockStalwartApi || require('../../api/stalwart');
  const keycloakApi = options.mockKeycloakApi || require('../../api/keycloak');

  // --- Routes ---

  // Health check
  app.get('/health', (req, res) => {
    res.json({ status: 'ok' });
  });

  // Landing page
  app.get('/', (req, res) => {
    if (req.isAuthenticated()) {
      return res.redirect('/home');
    }
    res.render('login', { title: 'MotherTree Account' });
  });

  // Home (authenticated)
  app.get('/home', requireAuth, (req, res) => {
    res.render('home', {
      title: 'Home',
      user: req.user,
      elementHost: process.env.ELEMENT_HOST || '',
      webmailHost: process.env.WEBMAIL_HOST || '',
      docsHost: process.env.DOCS_HOST || '',
      filesHost: process.env.FILES_HOST || '',
      jitsiHost: process.env.JITSI_HOST || '',
    });
  });

  // App passwords page (authenticated)
  app.get('/app-passwords', requireAuth, (req, res) => {
    res.render('app-passwords', {
      title: 'Device Passwords',
      user: req.user,
      imapHost: process.env.IMAP_HOST || '',
      smtpHost: process.env.SMTP_HOST || '',
      imapsPort: process.env.STALWART_IMAPS_APP_PORT || '',
      submissionPort: process.env.STALWART_SUBMISSION_APP_PORT || '',
      filesHost: process.env.FILES_HOST || '',
    });
  });

  // App passwords API
  app.get('/api/app-passwords', requireAuth, async (req, res) => {
    try {
      const passwords = await stalwartApi.listAppPasswords(req.user.email);
      res.json(passwords);
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.post('/api/app-passwords', verifyOrigin, requireAuth, async (req, res) => {
    try {
      const { deviceName } = req.body;
      if (!deviceName) {
        return res.status(400).json({ error: 'Device name is required' });
      }
      const defaultQuotaMb = parseInt(process.env.DEFAULT_EMAIL_QUOTA_MB || '5120', 10);
      const defaultQuotaBytes = defaultQuotaMb * 1024 * 1024;
      await stalwartApi.ensureUserExists(req.user.email, req.user.name, defaultQuotaBytes);
      const password = crypto.randomBytes(16).toString('base64url');
      await stalwartApi.createAppPassword(req.user.email, deviceName, password);
      res.json({ success: true, password });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  app.delete('/api/app-passwords/:name', verifyOrigin, requireAuth, async (req, res) => {
    try {
      await stalwartApi.revokeAppPassword(req.user.email, req.params.name);
      res.json({ success: true });
    } catch (error) {
      res.status(500).json({ error: 'Failed to revoke app password' });
    }
  });

  // Recovery
  app.get('/recover', (req, res) => {
    res.render('recover', {
      title: 'Account Recovery',
      error: null,
      success: null,
    });
  });

  app.post('/recover', verifyOrigin, async (req, res) => {
    try {
      const { tenantEmail, recoveryEmail } = req.body;
      if (!tenantEmail || !recoveryEmail) {
        return res.render('recover', {
          title: 'Account Recovery',
          error: 'Both email addresses are required',
          success: null,
        });
      }
      const result = await keycloakApi.initiateAccountRecovery({
        tenantEmail: tenantEmail.trim().toLowerCase(),
        recoveryEmail: recoveryEmail.trim().toLowerCase(),
      });
      res.render('recover', {
        title: 'Account Recovery',
        error: null,
        success: {
          message: result.message,
          recoveryEmailHint: result.recoveryEmailHint,
        },
      });
    } catch (error) {
      res.render('recover', {
        title: 'Account Recovery',
        error: error.message,
        success: null,
      });
    }
  });

  // Guest registration
  const guestRegistrationAttempts = new Map();
  function checkGuestRateLimit(ip) {
    const now = Date.now();
    const hourAgo = now - 60 * 60 * 1000;
    const attempts = (guestRegistrationAttempts.get(ip) || []).filter(t => t > hourAgo);
    guestRegistrationAttempts.set(ip, attempts);
    if (attempts.length >= 10) return false;
    attempts.push(now);
    guestRegistrationAttempts.set(ip, attempts);
    return true;
  }

  app.get('/guest-landing', async (req, res) => {
    const { email, doc, share } = req.query;
    if (!email || (!doc && !share)) {
      return res.redirect('/register');
    }
    try {
      const existingUser = await keycloakApi.findUserByEmail(email.toLowerCase());
      if (existingUser) {
        const needsSetup = existingUser.requiredActions && existingUser.requiredActions.length > 0;

        if (needsSetup) {
          const baseUrl = process.env.BASE_URL || '';
          let redirectAfterSetup = baseUrl;
          if (share) {
            redirectAfterSetup = `${baseUrl}/guest-complete?share=${encodeURIComponent(share)}`;
          } else if (doc) {
            redirectAfterSetup = `${baseUrl}/guest-complete?doc=${encodeURIComponent(doc)}`;
          }

          try {
            await keycloakApi.sendExecuteActionsEmail(existingUser.id, redirectAfterSetup);
          } catch (emailErr) {
            // non-fatal
          }

          const [local, domain] = email.split('@');
          let maskedEmail = email;
          if (local && domain) {
            const localMask = local.length > 2 ? local.slice(0, 2) + '***' : local + '***';
            const domainParts = domain.split('.');
            const domainMask = domainParts[0].length > 2
              ? domainParts[0].slice(0, 2) + '***.' + domainParts.slice(1).join('.')
              : domainParts[0] + '***.' + domainParts.slice(1).join('.');
            maskedEmail = localMask + '@' + domainMask;
          }

          return res.render('guest-setup', {
            title: 'Complete Your Account Setup',
            maskedEmail,
          });
        }

        if (share) {
          const filesHost = (process.env.BASE_URL || '').replace('account.', 'files.');
          const shareUrl = `/s/${encodeURIComponent(share)}`;
          return res.redirect(`${filesHost}/login?redirect_url=${encodeURIComponent(shareUrl)}`);
        }
        const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
        const docUrl = `/docs/${encodeURIComponent(doc)}/`;
        return res.redirect(`${docsHost}/login?redirect_url=${encodeURIComponent(docUrl)}`);
      }
    } catch (err) {
      // fall through
    }
    const params = new URLSearchParams({ email });
    if (doc) params.set('doc', doc);
    if (share) params.set('share', share);
    res.redirect(`/register?${params.toString()}`);
  });

  app.get('/register', (req, res) => {
    const email = req.query.email || '';
    const doc = req.query.doc || '';
    const share = req.query.share || '';
    let maskedEmail = '';
    if (email) {
      const [local, domain] = email.split('@');
      if (local && domain) {
        const localMask = local.length > 2 ? local.slice(0, 2) + '***' : local + '***';
        const domainParts = domain.split('.');
        const domainMask = domainParts[0].length > 2
          ? domainParts[0].slice(0, 2) + '***.' + domainParts.slice(1).join('.')
          : domainParts[0] + '***.' + domainParts.slice(1).join('.');
        maskedEmail = localMask + '@' + domainMask;
      }
    }
    res.render('register', {
      title: 'Guest Registration',
      error: null,
      success: null,
      emailDomain: process.env.EMAIL_DOMAIN || process.env.TENANT_DOMAIN || '',
      email,
      maskedEmail,
      doc,
      share,
    });
  });

  app.post('/api/register-guest', verifyOrigin, async (req, res) => {
    try {
      const clientIp = req.ip;
      if (!checkGuestRateLimit(clientIp)) {
        return res.status(429).json({ error: 'Too many registration attempts. Please try again later.' });
      }
      const { email, firstName, lastName } = req.body;
      if (!email || !firstName || !lastName) {
        return res.status(400).json({ error: 'All fields are required' });
      }
      const emailRegex = /^[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+$/;
      if (!emailRegex.test(email)) {
        return res.status(400).json({ error: 'Invalid email address' });
      }
      const tenantDomain = process.env.EMAIL_DOMAIN || process.env.TENANT_DOMAIN || '';
      if (tenantDomain && email.toLowerCase().endsWith('@' + tenantDomain.toLowerCase())) {
        return res.status(400).json({
          error: 'This email belongs to the organization. Please ask your admin for an invitation instead.'
        });
      }
      const existingUser = await keycloakApi.findUserByEmail(email.toLowerCase());
      if (existingUser) {
        return res.status(409).json({
          error: 'An account with this email already exists. Try signing in instead.'
        });
      }
      const { doc, share } = req.body;
      let redirectAfterSetup = process.env.BASE_URL || '';
      if (doc) {
        redirectAfterSetup = `${process.env.BASE_URL}/guest-complete?doc=${encodeURIComponent(doc)}`;
      } else if (share) {
        redirectAfterSetup = `${process.env.BASE_URL}/guest-complete?share=${encodeURIComponent(share)}`;
      }
      const result = await keycloakApi.createGuestUser({
        email: email.toLowerCase(),
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        redirectUri: redirectAfterSetup,
      });
      res.json({ success: true, userId: result.userId });
    } catch (error) {
      res.status(500).json({ error: error.message });
    }
  });

  // beginSetup
  app.get('/beginSetup', async (req, res) => {
    const { userId, next, token } = req.query;
    if (!userId || !next) {
      return res.status(400).send('Invalid setup link');
    }
    if (!checkBeginSetupRateLimit(req.ip)) {
      return res.status(429).send('Too many requests. Please try again later.');
    }
    const allowedDomain = process.env.TENANT_DOMAIN;
    try {
      const nextUrl = new URL(next);
      if (!nextUrl.hostname.endsWith(allowedDomain)) {
        return res.status(400).send('Invalid redirect URL');
      }
    } catch {
      return res.status(400).send('Invalid redirect URL');
    }
    if (!verifyBeginSetupToken(userId, token)) {
      return res.status(403).send('Invalid or expired setup link');
    }
    res.redirect(302, next);
  });

  // Guest complete — redirect through OIDC login (Issue #167)
  app.get('/guest-complete', (req, res) => {
    const { doc, share } = req.query;
    if (share) {
      const filesHost = (process.env.BASE_URL || '').replace('account.', 'files.');
      const shareUrl = `/s/${encodeURIComponent(share)}`;
      return res.redirect(`${filesHost}/login?redirect_url=${encodeURIComponent(shareUrl)}`);
    }
    if (doc) {
      const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
      const docUrl = `/docs/${encodeURIComponent(doc)}/`;
      return res.redirect(`${docsHost}/login?redirect_url=${encodeURIComponent(docUrl)}`);
    }
    const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
    res.redirect(docsHost || '/');
  });

  return app;
}

module.exports = { createTestApp };
