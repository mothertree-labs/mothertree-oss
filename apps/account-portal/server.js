const express = require('express');
const session = require('express-session');
const passport = require('passport');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const path = require('path');
const crypto = require('crypto');
const { Issuer, Strategy } = require('openid-client');

// Redis session store for HA deployments (multiple replicas)
const { RedisStore } = require('connect-redis');
const { createClient } = require('redis');

// Fail fast if required environment variables are not set
const REQUIRED_ENV_VARS = ['SESSION_SECRET', 'TENANT_DOMAIN'];
for (const envVar of REQUIRED_ENV_VARS) {
  if (!process.env[envVar]) {
    console.error(`FATAL: ${envVar} environment variable is required`);
    process.exit(1);
  }
}

const app = express();
const PORT = process.env.PORT || 3000;

// Trust proxy - required when behind nginx/load balancer for secure cookies
app.set('trust proxy', 1);

// Middleware
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      fontSrc: ["'self'"],
      imgSrc: ["'self'", "data:"],
      connectSrc: ["'self'"],
      frameSrc: ["'none'"],
      objectSrc: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"],
    }
  }
}));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

// Rate limiting - defaults: 100 req/15min, configurable via env vars
// Prod: 300/min (~5 QPS), Dev: 2000/min (~33 QPS) — set via RATE_LIMIT_MAX + RATE_LIMIT_WINDOW_MS
app.use(rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS, 10) || 15 * 60 * 1000,
  max: parseInt(process.env.RATE_LIMIT_MAX, 10) || 100,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => req.path === '/health' || req.path === '/version',
}));

// Policy URLs (configurable via environment variables)
app.locals.privacyPolicyUrl = process.env.PRIVACY_POLICY_URL || '';
app.locals.termsOfUseUrl = process.env.TERMS_OF_USE_URL || '';
app.locals.acceptableUsePolicyUrl = process.env.ACCEPTABLE_USE_POLICY_URL || '';

// View engine
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Initialize Redis client for session storage
// This enables HA with multiple replicas - sessions are shared across all pods
let sessionStore;
const redisHost = process.env.REDIS_HOST;
const redisPort = process.env.REDIS_PORT || '6379';
const redisPassword = process.env.REDIS_PASSWORD;

if (redisHost) {
  const redisUrl = redisPassword
    ? `redis://:${encodeURIComponent(redisPassword)}@${redisHost}:${redisPort}`
    : `redis://${redisHost}:${redisPort}`;
  const redisClient = createClient({
    url: redisUrl,
    socket: {
      reconnectStrategy: (retries) => {
        if (retries > 10) {
          console.error('Redis: Too many reconnection attempts, giving up');
          return new Error('Redis reconnection failed');
        }
        return Math.min(retries * 100, 3000);
      }
    }
  });

  redisClient.on('error', (err) => console.error('Redis Client Error:', err));
  redisClient.on('connect', () => console.log('Redis: Connected'));
  redisClient.on('reconnecting', () => console.log('Redis: Reconnecting...'));

  // Connect to Redis (async, but we don't need to wait - connect-redis handles it)
  redisClient.connect().catch(err => {
    console.error('Redis: Initial connection failed:', err.message);
    console.error('Redis: Sessions will use in-memory store (not HA-safe)');
  });

  sessionStore = new RedisStore({
    client: redisClient,
    prefix: 'account-portal:sess:',
  });
  console.log(`Redis: Session store configured (${redisHost}:${redisPort})`);
} else {
  console.warn('WARNING: REDIS_HOST not set - using in-memory sessions (not HA-safe)');
  console.warn('WARNING: With multiple replicas, OIDC login will fail randomly');
}

// Compute shared cookie domain from BASE_URL (e.g., https://account.dev.example.com -> .dev.example.com)
// This allows logout from one portal to clear cookies for both admin and account portals
const cookieDomain = (() => {
  try {
    const host = new URL(process.env.BASE_URL).hostname;
    // Strip first subdomain (account.) to get shared parent domain
    const parts = host.split('.');
    return parts.length > 2 ? '.' + parts.slice(1).join('.') : undefined;
  } catch { return undefined; }
})();

// Session - must be configured correctly for OIDC callback to work
// sameSite: 'lax' permits GET navigations from cross-origin (OIDC redirects are GET)
app.use(session({
  name: 'account.sid',      // Unique cookie name (admin portal uses 'admin.sid')
  store: sessionStore,      // Redis store for HA, undefined falls back to MemoryStore
  secret: process.env.SESSION_SECRET,
  resave: false,            // Don't save session if unmodified (Redis handles expiry)
  saveUninitialized: false, // Don't create session until something is stored
  cookie: {
    domain: cookieDomain,   // Shared parent domain so logout clears both portals
    secure: true,
    httpOnly: true,
    sameSite: 'lax',        // Permits cross-origin GET (OIDC redirects) but blocks cross-origin POST
    maxAge: 30 * 24 * 60 * 60 * 1000 // 30 days (matches Remember Me / offline token lifespan)
  }
}));

// Passport
app.use(passport.initialize());
app.use(passport.session());
app.use(tokenRefreshMiddleware);

passport.serializeUser((user, done) => done(null, user));
passport.deserializeUser((user, done) => done(null, user));

// Origin verification middleware for CSRF protection on state-changing requests
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

// HMAC token generation/verification for beginSetup endpoint
const BEGINSETUP_SECRET = process.env.BEGINSETUP_SECRET || process.env.SESSION_SECRET;

function generateBeginSetupToken(userId) {
  // Token = timestamp:hmac(userId + timestamp)
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const hmac = crypto.createHmac('sha256', BEGINSETUP_SECRET)
    .update(userId + ':' + timestamp)
    .digest('hex');
  return timestamp + ':' + hmac;
}

function verifyBeginSetupToken(userId, token) {
  if (!token) return false;
  const parts = token.split(':');
  if (parts.length !== 2) return false;
  const [timestamp, providedHmac] = parts;
  // Reject tokens older than 7 days (invitation link lifespan)
  const age = Math.floor(Date.now() / 1000) - parseInt(timestamp, 10);
  if (isNaN(age) || age < 0 || age > 7 * 24 * 60 * 60) return false;
  const expectedHmac = crypto.createHmac('sha256', BEGINSETUP_SECRET)
    .update(userId + ':' + timestamp)
    .digest('hex');
  // Constant-time comparison to prevent timing attacks
  return crypto.timingSafeEqual(Buffer.from(providedHmac, 'hex'), Buffer.from(expectedHmac, 'hex'));
}

// Rate limiter for beginSetup endpoint
const beginSetupAttempts = new Map();
function checkBeginSetupRateLimit(ip) {
  const now = Date.now();
  const windowMs = 15 * 60 * 1000; // 15 minutes
  const maxAttempts = 20;
  const attempts = (beginSetupAttempts.get(ip) || []).filter(t => t > now - windowMs);
  beginSetupAttempts.set(ip, attempts);
  if (attempts.length >= maxAttempts) return false;
  attempts.push(now);
  beginSetupAttempts.set(ip, attempts);
  return true;
}

// Initialize OIDC
async function initializeOIDC() {
  const issuerUrl = process.env.KEYCLOAK_ISSUER;
  const internalUrl = process.env.KEYCLOAK_INTERNAL_URL;
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  const clientSecret = process.env.KEYCLOAK_CLIENT_SECRET;
  const callbackUrl = `${process.env.BASE_URL}/auth/callback`;

  console.log('Initializing OIDC with issuer:', issuerUrl);

  let keycloakIssuer;
  if (internalUrl) {
    // Use internal Keycloak service for server-to-server calls (avoids ingress PROXY protocol)
    const internalIssuer = `${internalUrl}/realms/${process.env.KEYCLOAK_REALM}`;
    console.log('Using internal URL for discovery:', internalIssuer);
    const res = await fetch(`${internalIssuer}/.well-known/openid-configuration`);
    if (!res.ok) throw new Error(`OIDC discovery failed: ${res.status}`);
    const metadata = await res.json();
    // Rewrite server-to-server endpoints to use internal URL
    const serverEndpoints = ['token_endpoint', 'userinfo_endpoint', 'jwks_uri',
      'introspection_endpoint', 'revocation_endpoint'];
    for (const key of serverEndpoints) {
      if (metadata[key]) {
        metadata[key] = metadata[key].replace(metadata.issuer, internalIssuer);
      }
    }
    keycloakIssuer = new Issuer(metadata);
  } else {
    keycloakIssuer = await Issuer.discover(issuerUrl);
  }
  console.log('Discovered issuer:', keycloakIssuer.issuer);

  // Main client - uses passkey browser flow
  const client = new keycloakIssuer.Client({
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uris: [callbackUrl],
    response_types: ['code'],
  });

  passport.use('oidc', new Strategy(
    { client, passReqToCallback: true },
    (req, tokenSet, userinfo, done) => {
      const user = {
        id: userinfo.sub,
        email: userinfo.email,
        name: userinfo.name || userinfo.preferred_username,
        roles: tokenSet.claims().realm_access?.roles || [],
        accessToken: tokenSet.access_token,
        refreshToken: tokenSet.refresh_token,
        tokenExpiresAt: tokenSet.expires_at,
      };
      return done(null, user);
    }
  ));

  // Registration client - dedicated callback for new user registration (no session state needed)
  const registrationCallbackUrl = `${process.env.BASE_URL}/registration-callback`;

  const registrationClient = new keycloakIssuer.Client({
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uris: [registrationCallbackUrl],
    response_types: ['code'],
  });

  passport.use('oidc-registration', new Strategy(
    { client: registrationClient, passReqToCallback: true },
    (req, tokenSet, userinfo, done) => {
      const user = {
        id: userinfo.sub,
        email: userinfo.email,
        name: userinfo.name || userinfo.preferred_username,
        roles: tokenSet.claims().realm_access?.roles || [],
        accessToken: tokenSet.access_token,
        refreshToken: tokenSet.refresh_token,
        tokenExpiresAt: tokenSet.expires_at,
      };
      return done(null, user);
    }
  ));

  // Store client reference for token refresh middleware
  app.locals.oidcClient = client;

  return client;
}

// Token refresh middleware — transparently refreshes expired access tokens
// using the stored refresh token (5-minute window before expiry)
function tokenRefreshMiddleware(req, res, next) {
  if (!req.isAuthenticated() || !req.user.refreshToken || !req.user.tokenExpiresAt) {
    return next();
  }

  const now = Math.floor(Date.now() / 1000);
  const expiresAt = req.user.tokenExpiresAt;
  const REFRESH_WINDOW = 5 * 60; // 5 minutes before expiry

  if (now < expiresAt - REFRESH_WINDOW) {
    return next(); // Token still fresh
  }

  const client = req.app.locals.oidcClient;
  if (!client) {
    return next();
  }

  client.refresh(req.user.refreshToken)
    .then((tokenSet) => {
      req.user.accessToken = tokenSet.access_token;
      req.user.refreshToken = tokenSet.refresh_token || req.user.refreshToken;
      req.user.tokenExpiresAt = tokenSet.expires_at;
      next();
    })
    .catch((err) => {
      console.error('Token refresh failed:', err.message);
      next();
    });
}

// Auth middleware
function requireAuth(req, res, next) {
  if (req.isAuthenticated()) {
    return next();
  }
  res.redirect('/');
}

// Routes
app.get('/', (req, res) => {
  if (req.isAuthenticated()) {
    return res.redirect('/home');
  }
  res.render('login', { title: 'MotherTree Account' });
});

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

app.get('/auth/login', (req, res, next) => {
  // Ensure session is saved before OIDC redirect so state/nonce survive the round-trip
  req.session.save((err) => {
    if (err) console.error('Session save error:', err);
    passport.authenticate('oidc', { scope: 'openid email profile' })(req, res, next);
  });
});

app.get('/auth/callback',
  passport.authenticate('oidc', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    // Check if this is a registration completion flow
    const isRegistrationCompletion = req.session.isRegistrationCompletion;

    // Check if user needs email swapped from recovery to tenant
    try {
      const keycloakApi = require('./api/keycloak');
      const swapResult = await keycloakApi.swapToTenantEmailIfNeeded(req.user.id);
      if (swapResult.swapped) {
        console.log(`Email swapped for user ${req.user.id}: ${swapResult.newEmail}`);
      }
    } catch (err) {
      console.error('Email swap check failed (non-fatal):', err.message);
    }

    // Ensure passkey is ordered before password (non-blocking)
    try {
      const keycloakApi = require('./api/keycloak');
      keycloakApi.ensurePasskeyFirst(req.user.id).catch(err =>
        console.error('ensurePasskeyFirst failed on login:', err.message)
      );
    } catch (err) {
      console.error('ensurePasskeyFirst setup failed:', err.message);
    }

    // If this is registration completion, redirect to home page
    if (isRegistrationCompletion) {
      delete req.session.isRegistrationCompletion;
      delete req.session.postLoginRedirect;
      console.log('Registration complete, redirecting to /home');
      return res.redirect('/home');
    }

    // Check if we should redirect somewhere specific (e.g., after registration)
    const postLoginRedirect = req.session.postLoginRedirect;
    if (postLoginRedirect) {
      delete req.session.postLoginRedirect;
      return res.redirect(postLoginRedirect);
    }

    // Default: go to home page
    res.redirect('/home');
  }
);

app.get('/auth/logout', (req, res) => {
  // Build Keycloak logout URL to end the SSO session
  const keycloakLogoutUrl = `${process.env.KEYCLOAK_ISSUER}/protocol/openid-connect/logout`;
  const postLogoutRedirect = encodeURIComponent(process.env.BASE_URL);

  req.logout(() => {
    req.session.destroy(() => {
      // Clear both portal cookies on the shared domain
      const cookieOpts = { domain: cookieDomain, path: '/' };
      res.clearCookie('admin.sid', cookieOpts);
      res.clearCookie('account.sid', cookieOpts);
      // Redirect to Keycloak logout to end the SSO session
      res.redirect(`${keycloakLogoutUrl}?post_logout_redirect_uri=${postLogoutRedirect}&client_id=${process.env.KEYCLOAK_CLIENT_ID}`);
    });
  });
});

app.get('/auth/error', (req, res) => {
  res.render('error', {
    title: 'Authentication Error',
    message: 'There was a problem signing you in. Please try again.'
  });
});

// Device Passwords (app-specific passwords for email clients)
const stalwartApi = require('./api/stalwart');

app.get('/app-passwords', requireAuth, (req, res) => {
  res.render('app-passwords', {
    title: 'Device Passwords',
    user: req.user,
    imapHost: process.env.IMAP_HOST || process.env.MAIL_HOST || '',
    smtpHost: process.env.SMTP_HOST || process.env.MAIL_HOST || '',
    imapsPort: process.env.STALWART_IMAPS_APP_PORT || process.env.STALWART_IMAPS_PORT || '',
    submissionPort: process.env.STALWART_SUBMISSION_APP_PORT || process.env.STALWART_SUBMISSION_PORT || '',
    filesHost: process.env.FILES_HOST || '',
  });
});

app.get('/api/app-passwords', requireAuth, async (req, res) => {
  try {
    const passwords = await stalwartApi.listAppPasswords(req.user.email);
    res.json(passwords);
  } catch (error) {
    console.error('List app passwords error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/app-passwords', verifyOrigin, requireAuth, async (req, res) => {
  try {
    const { deviceName } = req.body;
    if (!deviceName) {
      return res.status(400).json({ error: 'Device name is required' });
    }

    // Lazy provisioning: ensure user exists in Stalwart before creating app password
    const defaultQuotaMb = parseInt(process.env.DEFAULT_EMAIL_QUOTA_MB || '5120', 10);
    const defaultQuotaBytes = defaultQuotaMb * 1024 * 1024;
    await stalwartApi.ensureUserExists(req.user.email, req.user.name, defaultQuotaBytes);

    // Generate a cryptographically random password
    const password = crypto.randomBytes(16).toString('base64url');

    await stalwartApi.createAppPassword(req.user.email, deviceName, password);

    res.json({ success: true, password });
  } catch (error) {
    console.error('Create app password error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.delete('/api/app-passwords/:name', verifyOrigin, requireAuth, async (req, res) => {
  try {
    await stalwartApi.revokeAppPassword(req.user.email, req.params.name);
    res.json({ success: true });
  } catch (error) {
    console.error('Revoke app password error');
    res.status(500).json({ error: 'Failed to revoke app password' });
  }
});

// Registration callback - dedicated endpoint for new user registration
// The URL itself indicates this is a registration flow - NO SESSION STATE NEEDED
app.get('/registration-callback',
  passport.authenticate('oidc-registration', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    console.log(`Registration callback for user ${req.user.id}, redirecting to /home`);

    // Swap email from recovery to tenant
    try {
      const keycloakApi = require('./api/keycloak');
      const swapResult = await keycloakApi.swapToTenantEmailIfNeeded(req.user.id);
      if (swapResult.swapped) {
        console.log(`Email swapped for user ${req.user.id}: ${swapResult.newEmail}`);
      }
    } catch (err) {
      console.error('Email swap failed:', err.message);
    }

    // Ensure passkey is ordered before password (non-blocking)
    try {
      const keycloakApi = require('./api/keycloak');
      keycloakApi.ensurePasskeyFirst(req.user.id).catch(err =>
        console.error('ensurePasskeyFirst failed on registration:', err.message)
      );
    } catch (err) {
      console.error('ensurePasskeyFirst setup failed:', err.message);
    }

    // Redirect to home page
    res.redirect('/home');
  }
);

// Complete registration endpoint - swaps email and redirects to home page
// This is the redirect target after passkey registration for NEW USERS (not admins)
// Registration completion - uses dedicated callback URL (no session state needed)
app.get('/complete-registration', (req, res, next) => {
  console.log('Complete registration: initiating OIDC with /registration-callback');
  // Ensure session is saved before OIDC redirect so state/nonce survive the round-trip
  req.session.save((err) => {
    if (err) console.error('Session save error:', err);
    passport.authenticate('oidc-registration', { scope: 'openid email profile' })(req, res, next);
  });
});

// Dedicated callback for registration completion - doesn't require tenant-admin
app.get('/registration/callback',
  passport.authenticate('oidc', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    // Swap email from recovery to tenant
    try {
      const keycloakApi = require('./api/keycloak');
      const swapResult = await keycloakApi.swapToTenantEmailIfNeeded(req.user.id);
      if (swapResult.swapped) {
        console.log(`Email swapped for user ${req.user.id}: ${swapResult.newEmail}`);
      }
    } catch (err) {
      console.error('Email swap failed:', err.message);
    }

    // Ensure passkey is ordered before password (non-blocking)
    try {
      const keycloakApi = require('./api/keycloak');
      keycloakApi.ensurePasskeyFirst(req.user.id).catch(err =>
        console.error('ensurePasskeyFirst failed on registration:', err.message)
      );
    } catch (err) {
      console.error('ensurePasskeyFirst setup failed:', err.message);
    }

    // Redirect to home page
    res.redirect('/home');
  }
);

// Begin Setup - intercepts Keycloak action links to swap email first
// This is hit BEFORE Keycloak, ensuring the email is correct when the user registers
app.get('/beginSetup', async (req, res) => {
  const { userId, next, token } = req.query;

  if (!userId || !next) {
    console.error('beginSetup: missing userId or next parameter');
    return res.status(400).send('Invalid setup link');
  }

  // Rate limiting
  if (!checkBeginSetupRateLimit(req.ip)) {
    console.error('beginSetup: rate limit exceeded for', req.ip);
    return res.status(429).send('Too many requests. Please try again later.');
  }

  // Validate the redirect URL - only allow redirects to the application's own domain
  const allowedDomain = process.env.TENANT_DOMAIN;
  try {
    const nextUrl = new URL(next);
    if (!nextUrl.hostname.endsWith(allowedDomain)) {
      console.error(`beginSetup: rejected redirect to disallowed domain: ${nextUrl.hostname}`);
      return res.status(400).send('Invalid redirect URL');
    }
  } catch {
    console.error('beginSetup: invalid next URL:', next);
    return res.status(400).send('Invalid redirect URL');
  }

  // Verify HMAC token to prevent unauthenticated access
  if (!verifyBeginSetupToken(userId, token)) {
    console.error('beginSetup: invalid or missing HMAC token for user', userId);
    return res.status(403).send('Invalid or expired setup link');
  }

  // Do NOT swap email here — the action token's `eml` claim contains the recovery
  // email (set when the token was created). Keycloak validates that `eml` matches
  // the user's current email. The swap happens later in /complete-registration
  // after Keycloak has processed the action token.

  // Set a cookie with userId + token so the WebAuthn registration FTL can build
  // the /switch-to-magic-link URL if the device lacks a platform authenticator.
  // httpOnly: false so client-side JS can read it on the auth.* domain.
  const setupInfo = Buffer.from(JSON.stringify({ userId, token })).toString('base64url');
  res.cookie('mt-setup-info', setupInfo, {
    maxAge: 30 * 60 * 1000,
    httpOnly: false,
    secure: true,
    sameSite: 'lax',
    domain: cookieDomain,
  });

  console.log(`beginSetup: validated token for user ${userId}, redirecting to Keycloak`);
  res.redirect(302, next);
});

// Switch to Magic Link - swaps WebAuthn required action for magic-link
// Called from the WebAuthn registration page when device lacks platform authenticator
app.get('/switch-to-magic-link', async (req, res) => {
  const { userId, token, next } = req.query;

  if (!userId || !next) {
    console.error('switch-to-magic-link: missing userId or next parameter');
    return res.status(400).send('Invalid request');
  }

  // Rate limiting (reuse beginSetup rate limiter)
  if (!checkBeginSetupRateLimit(req.ip)) {
    console.error('switch-to-magic-link: rate limit exceeded for', req.ip);
    return res.status(429).send('Too many requests. Please try again later.');
  }

  // Validate the redirect URL — must be on the tenant domain or a subdomain.
  // Reconstruct from parsed URL to prevent open-redirect via user-controlled input.
  const allowedDomain = process.env.TENANT_DOMAIN;
  let validatedNext;
  try {
    const nextUrl = new URL(next);
    if (nextUrl.hostname !== allowedDomain && !nextUrl.hostname.endsWith('.' + allowedDomain)) {
      console.error(`switch-to-magic-link: rejected redirect to disallowed domain: ${nextUrl.hostname}`);
      return res.status(400).send('Invalid redirect URL');
    }
    if (nextUrl.protocol !== 'https:') {
      console.error(`switch-to-magic-link: rejected non-HTTPS redirect: ${nextUrl.protocol}`);
      return res.status(400).send('Invalid redirect URL');
    }
    // Reconstruct URL from validated components to satisfy SSRF/redirect checks
    validatedNext = nextUrl.toString();
  } catch {
    console.error('switch-to-magic-link: invalid next URL:', next);
    return res.status(400).send('Invalid redirect URL');
  }

  // Verify HMAC token
  if (!verifyBeginSetupToken(userId, token)) {
    console.error('switch-to-magic-link: invalid or missing HMAC token for user', userId);
    return res.status(403).send('Invalid or expired setup link');
  }

  try {
    // Remove webauthn required action and mark user as magic-link auth
    await keycloakApi.removeRequiredAction(userId, 'webauthn-register-passwordless');
    await keycloakApi.setUserAuthMethod(userId, 'magic-link');
    console.log(`switch-to-magic-link: removed webauthn action, set authMethod=magic-link for user ${userId}`);

    // Generate a magic-link login URL that bypasses the stale session
    // (Keycloak's auth session still has the old required action; a fresh
    // magic-link token creates a new session with no required actions.)
    const accountPortalBase = process.env.BASE_URL; // e.g. https://account.dev.mother-tree.org
    const magicLink = await keycloakApi.createMagicLink(userId, `${accountPortalBase}/magic-link-landing`);
    console.log(`switch-to-magic-link: generated magic link for user ${userId}`);

    // Clear the setup-info cookie
    res.clearCookie('mt-setup-info', { domain: cookieDomain, path: '/' });

    // Redirect user to the magic link (authenticates them in a fresh session)
    res.redirect(302, magicLink);
  } catch (err) {
    console.error('switch-to-magic-link: failed:', err.message);
    return res.status(500).send('Failed to switch authentication method. Please try again.');
  }
});

// Magic-link landing page — receives the redirect from Keycloak's magic-link
// action token (with ?code=...&session_state=...) after authenticating the user.
// We strip the OIDC params and redirect to /complete-registration, which starts
// its own OIDC flow. Since the user now has a Keycloak session, it completes
// immediately without user interaction.
app.get('/magic-link-landing', (req, res) => {
  console.log('magic-link-landing: redirecting to /complete-registration');
  res.redirect('/complete-registration');
});

// Account Recovery - public pages (no auth required)
app.get('/recover', (req, res) => {
  res.render('recover', {
    title: 'Account Recovery',
    error: null,
    success: null,
  });
});

const keycloakApi = require('./api/keycloak');

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
    console.error('Recovery error:', error.message);
    res.render('recover', {
      title: 'Account Recovery',
      error: error.message,
      success: null,
    });
  }
});

// Guest Registration - public pages (no auth required)
// Rate limiting: simple in-memory tracker (max 10 registrations per IP per hour)
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

// Guest complete - redirect to the document/file after passkey registration.
// Redirects through OIDC login so the guest arrives authenticated in Nextcloud/Docs,
// avoiding the redundant name prompt on share pages (Issue #167).
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
  // Fallback: go to the main docs page
  const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
  res.redirect(docsHost || '/');
});

// Guest landing - smart redirect based on whether user exists and is set up
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
        // User was provisioned but hasn't completed passkey setup yet.
        // Send Keycloak setup email and show instructions page.
        const baseUrl = process.env.BASE_URL || '';
        let redirectAfterSetup = baseUrl;
        if (share) {
          redirectAfterSetup = `${baseUrl}/guest-complete?share=${encodeURIComponent(share)}`;
        } else if (doc) {
          redirectAfterSetup = `${baseUrl}/guest-complete?doc=${encodeURIComponent(doc)}`;
        }

        try {
          await keycloakApi.sendExecuteActionsEmail(existingUser.id, redirectAfterSetup);
          console.log(`[GUEST-LANDING] Sent setup email for ${email}`);
        } catch (emailErr) {
          console.error(`[GUEST-LANDING] Failed to send setup email:`, emailErr.message);
        }

        // Mask email for display
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

      // User is fully set up - redirect through OIDC login so they arrive
      // authenticated, avoiding the redundant name prompt (Issue #167).
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
    console.error('Guest landing lookup error:', err.message);
  }

  // User doesn't exist - send them to registration
  const params = new URLSearchParams({ email });
  if (doc) params.set('doc', doc);
  if (share) params.set('share', share);
  res.redirect(`/register?${params.toString()}`);
});

app.get('/register', (req, res) => {
  const email = req.query.email || '';
  const doc = req.query.doc || '';
  const share = req.query.share || '';

  // Mask email: show first 2 chars of local part + *** + @ + first 2 chars of domain + ***
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

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email address' });
    }

    // Reject tenant domain emails — guests must use external emails
    const tenantDomain = process.env.EMAIL_DOMAIN || process.env.TENANT_DOMAIN || '';
    if (tenantDomain && email.toLowerCase().endsWith('@' + tenantDomain.toLowerCase())) {
      return res.status(400).json({
        error: 'This email belongs to the organization. Please ask your admin for an invitation instead.'
      });
    }

    // Check if user already exists
    const existingUser = await keycloakApi.findUserByEmail(email.toLowerCase());
    if (existingUser) {
      return res.status(409).json({
        error: 'An account with this email already exists. Try signing in instead.'
      });
    }

    const { doc, share } = req.body;

    // Build the redirect URL - must be within account portal domain (Keycloak redirect_uri validation)
    let redirectAfterSetup = process.env.BASE_URL || '';
    if (doc) {
      redirectAfterSetup = `${process.env.BASE_URL}/guest-complete?doc=${encodeURIComponent(doc)}`;
    } else if (share) {
      redirectAfterSetup = `${process.env.BASE_URL}/guest-complete?share=${encodeURIComponent(share)}`;
    }

    // Create the guest user
    const result = await keycloakApi.createGuestUser({
      email: email.toLowerCase(),
      firstName: firstName.trim(),
      lastName: lastName.trim(),
      redirectUri: redirectAfterSetup,
    });

    res.json({ success: true, userId: result.userId });
  } catch (error) {
    console.error('Guest registration error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

// Ensure passkey credential priority — called from login-username.ftl via
// sendBeacon before form submission so Keycloak's AuthenticationSelectionResolver
// picks the WebAuthn authenticator instead of the password form.
// Unauthenticated by design (user hasn't logged in yet). Rate-limited per IP.
// Response is always 200 to avoid leaking user existence.
// The beacon uses application/x-www-form-urlencoded (CORS simple request),
// so no preflight is needed and no CORS response headers are required
// (sendBeacon ignores responses).
const ensurePasskeyAttempts = new Map();
app.post('/api/ensure-passkey-priority', async (req, res) => {
  // Rate limit: 30 requests per IP per 15 minutes
  const now = Date.now();
  const windowMs = 15 * 60 * 1000;
  const maxAttempts = 30;
  const ip = req.ip;
  const attempts = (ensurePasskeyAttempts.get(ip) || []).filter(t => t > now - windowMs);
  if (attempts.length >= maxAttempts) {
    return res.json({ ok: true }); // Silent rate limit
  }
  attempts.push(now);
  ensurePasskeyAttempts.set(ip, attempts);

  const { email } = req.body;
  if (!email || typeof email !== 'string') {
    return res.json({ ok: true });
  }

  try {
    const keycloakApi = require('./api/keycloak');
    const user = await keycloakApi.findUserByEmail(email);
    if (user) {
      await keycloakApi.ensurePasskeyFirst(user.id);
    }
  } catch (err) {
    console.error('ensure-passkey-priority error (non-fatal):', err.message);
  }

  res.json({ ok: true });
});

// Guest Provisioning API — called by Nextcloud guest_bridge app
// Authenticates via API key (not user session) to create guest users programmatically
const GUEST_PROVISIONING_API_KEY = process.env.GUEST_PROVISIONING_API_KEY;

// Rate limiter for guest provisioning API (max 30 per IP per hour)
const guestProvisioningAttempts = new Map();
function checkGuestProvisioningRateLimit(ip) {
  const now = Date.now();
  const hourAgo = now - 60 * 60 * 1000;
  const attempts = (guestProvisioningAttempts.get(ip) || []).filter(t => t > hourAgo);
  guestProvisioningAttempts.set(ip, attempts);
  if (attempts.length >= 30) return false;
  attempts.push(now);
  guestProvisioningAttempts.set(ip, attempts);
  return true;
}

app.post('/api/provision-guest', async (req, res) => {
  // Authenticate via API key
  const apiKey = req.get('X-API-Key');
  if (!GUEST_PROVISIONING_API_KEY || !apiKey || apiKey !== GUEST_PROVISIONING_API_KEY) {
    return res.status(401).json({ success: false, error: 'Unauthorized' });
  }

  // Rate limit
  if (!checkGuestProvisioningRateLimit(req.ip)) {
    return res.status(429).json({ success: false, error: 'Too many requests' });
  }

  try {
    const { email, firstName, lastName, redirectUri, shareContext } = req.body;

    if (!email) {
      return res.status(400).json({ success: false, error: 'Email is required' });
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ success: false, error: 'Invalid email format' });
    }

    // Reject tenant domain emails — guests must use external emails
    const tenantDomain = process.env.EMAIL_DOMAIN || process.env.TENANT_DOMAIN || '';
    if (tenantDomain && email.toLowerCase().endsWith('@' + tenantDomain.toLowerCase())) {
      return res.status(400).json({
        success: false,
        error: 'Cannot create guest for tenant domain email'
      });
    }

    // Check if user already exists
    const existingUser = await keycloakApi.findUserByEmail(email.toLowerCase());
    if (existingUser) {
      // User already exists — send share notification email if share context provided.
      // Without this, existing users get no notification when shared with via email
      // (sharebymail's email is suppressed by guest_bridge, and there's no other path).
      if (shareContext && shareContext.shareToken) {
        try {
          const baseUrl = process.env.BASE_URL || '';
          const guestLandingUrl = `${baseUrl}/guest-landing?email=${encodeURIComponent(email)}&share=${encodeURIComponent(shareContext.shareToken)}`;
          const mailer = require('./api/mailer');
          await mailer.sendShareInviteEmail({
            to: email,
            sharerName: shareContext.sharerName || 'Someone',
            documentName: shareContext.documentName || 'a file',
            guestLandingUrl,
            brandName: process.env.TENANT_DISPLAY_NAME || 'Mothertree',
          });
          console.log(`[PROVISION-GUEST] Sent share invite email to existing user ${email}`);
        } catch (emailErr) {
          console.error(`[PROVISION-GUEST] Failed to send invite email to existing user:`, emailErr.message);
        }
      }
      return res.json({ success: true, userId: existingUser.id, existing: true });
    }

    // Create the guest user
    const result = await keycloakApi.createGuestUser({
      email: email.toLowerCase(),
      firstName: (firstName || '').trim() || undefined,
      lastName: (lastName || '').trim() || undefined,
      redirectUri: redirectUri || undefined,
      skipEmail: !!shareContext,  // We'll send our own contextual email
    });

    console.log(`[PROVISION-GUEST] Created guest user: ${email} (${result.userId})`);

    // Send contextual invite email when share context is provided
    if (shareContext && shareContext.shareToken) {
      try {
        const baseUrl = process.env.BASE_URL || '';
        const guestLandingUrl = `${baseUrl}/guest-landing?email=${encodeURIComponent(email)}&share=${encodeURIComponent(shareContext.shareToken)}`;
        const mailer = require('./api/mailer');
        await mailer.sendShareInviteEmail({
          to: email,
          sharerName: shareContext.sharerName || 'Someone',
          documentName: shareContext.documentName || 'a file',
          guestLandingUrl,
          brandName: process.env.TENANT_DISPLAY_NAME || 'Mothertree',
        });
        console.log(`[PROVISION-GUEST] Sent share invite email to ${email}`);
      } catch (emailErr) {
        console.error(`[PROVISION-GUEST] Failed to send invite email:`, emailErr.message);
        // Non-fatal — user is created, they can be re-invited
      }
    }

    res.json({ success: true, userId: result.userId });
  } catch (error) {
    console.error('[PROVISION-GUEST] Error:', error.message);
    res.status(500).json({ success: false, error: error.message });
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Version endpoint (public, no auth)
app.get('/version', (req, res) => {
  res.json({
    version: process.env.RELEASE_VERSION || 'unknown',
    environment: process.env.NODE_ENV || 'development',
  });
});

// Global error handler - catches unhandled errors like OIDC session failures
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err.message);

  // If it's an OIDC session error, redirect to home to start fresh login
  if (err.message && err.message.includes('did not find expected authorization request')) {
    return res.redirect('/?error=session_expired');
  }

  // Otherwise render error page
  res.status(500).render('error', {
    title: 'Error',
    message: 'An unexpected error occurred. Please try again.'
  });
});

// Start server
async function start() {
  try {
    await initializeOIDC();
    app.listen(PORT, '0.0.0.0', () => {
      console.log(`Account Portal running on port ${PORT}`);
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

start();
