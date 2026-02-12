const express = require('express');
const session = require('express-session');
const passport = require('passport');
const helmet = require('helmet');
const path = require('path');
const crypto = require('crypto');
const { Issuer, Strategy } = require('openid-client');

// Redis session store for HA deployments (multiple replicas)
const RedisStore = require('connect-redis').default;
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
      scriptSrc: ["'self'", "'unsafe-inline'", "https://cdn.tailwindcss.com"],
      styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com", "https://cdn.tailwindcss.com"],
      fontSrc: ["'self'", "https://fonts.gstatic.com"],
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
    maxAge: 24 * 60 * 60 * 1000 // 24 hours
  }
}));

// Passport
app.use(passport.initialize());
app.use(passport.session());

passport.serializeUser((user, done) => done(null, user));
passport.deserializeUser((user, done) => done(null, user));

// Origin verification middleware for CSRF protection on state-changing requests
function verifyOrigin(req, res, next) {
  const origin = req.get('Origin');
  const referer = req.get('Referer');
  const source = origin || referer;
  if (source) {
    try {
      const url = new URL(source);
      if (!url.hostname.endsWith(process.env.TENANT_DOMAIN)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
    } catch {
      return res.status(403).json({ error: 'Forbidden' });
    }
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
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  const clientSecret = process.env.KEYCLOAK_CLIENT_SECRET;
  const callbackUrl = `${process.env.BASE_URL}/auth/callback`;

  console.log('Initializing OIDC with issuer:', issuerUrl);

  const keycloakIssuer = await Issuer.discover(issuerUrl);
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
      };
      return done(null, user);
    }
  ));

  return client;
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
    return res.redirect('/app-passwords');
  }
  res.render('home', { title: 'MotherTree Account' });
});

app.get('/auth/login', passport.authenticate('oidc', { scope: 'openid email profile' }));

app.get('/auth/callback',
  passport.authenticate('oidc', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    // Use WEBMAIL_HOST which includes the env prefix (e.g., webmail.dev.example.com)
    const webmailHost = process.env.WEBMAIL_HOST;
    const webmailUrl = webmailHost ? `https://${webmailHost}` : null;

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

    // If this is registration completion, redirect to webmail (regular users, not admins)
    if (isRegistrationCompletion) {
      delete req.session.isRegistrationCompletion;
      delete req.session.postLoginRedirect;
      if (webmailUrl) {
        console.log(`Registration complete, redirecting to: ${webmailUrl}`);
        return res.redirect(webmailUrl);
      }
      // Fallback: if no webmail configured, just show success message
      console.log('Registration complete, no WEBMAIL_HOST configured');
    }

    // Check if we should redirect somewhere specific (e.g., after registration)
    const postLoginRedirect = req.session.postLoginRedirect;
    if (postLoginRedirect) {
      delete req.session.postLoginRedirect;
      return res.redirect(postLoginRedirect);
    }

    // Default: go to app-passwords (user self-service home)
    res.redirect('/app-passwords');
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
    console.error('List app passwords error:', error);
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
    await stalwartApi.ensureUserExists(req.user.email, req.user.name);

    // Generate a cryptographically random password
    const password = crypto.randomBytes(16).toString('base64url');

    await stalwartApi.createAppPassword(req.user.email, deviceName, password);

    res.json({ success: true, password });
  } catch (error) {
    console.error('Create app password error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.delete('/api/app-passwords/:name', verifyOrigin, requireAuth, async (req, res) => {
  try {
    await stalwartApi.revokeAppPassword(req.user.email, req.params.name);
    res.json({ success: true });
  } catch (error) {
    console.error('Revoke app password error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Registration callback - dedicated endpoint for new user registration
// The URL itself indicates this is a registration flow - NO SESSION STATE NEEDED
app.get('/registration-callback',
  passport.authenticate('oidc-registration', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    const webmailHost = process.env.WEBMAIL_HOST;
    const webmailUrl = webmailHost ? `https://${webmailHost}` : '/';

    console.log(`Registration callback for user ${req.user.id}, redirecting to ${webmailUrl}`);

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

    // Always redirect to webmail
    res.redirect(webmailUrl);
  }
);

// Complete registration endpoint - swaps email and redirects to webmail
// This is the redirect target after passkey registration for NEW USERS (not admins)
// Registration completion - uses dedicated callback URL (no session state needed)
app.get('/complete-registration', (req, res, next) => {
  console.log('Complete registration: initiating OIDC with /registration-callback');
  // Use a dedicated callback URL - the URL itself indicates this is a registration flow
  // No session state needed!
  passport.authenticate('oidc-registration', { scope: 'openid email profile' })(req, res, next);
});

// Dedicated callback for registration completion - doesn't require tenant-admin
app.get('/registration/callback',
  passport.authenticate('oidc', { failureRedirect: '/auth/error' }),
  async (req, res) => {
    // Use WEBMAIL_HOST directly (already includes env prefix like webmail.dev.example.com)
    const webmailHost = process.env.WEBMAIL_HOST || `webmail.${process.env.TENANT_DOMAIN}`;
    const webmailUrl = `https://${webmailHost}`;

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

    // Always redirect to webmail - regular users don't need admin access
    res.redirect(webmailUrl);
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

  console.log(`beginSetup: swapping email for user ${userId} before redirecting to Keycloak`);

  try {
    const keycloakApi = require('./api/keycloak');
    const swapResult = await keycloakApi.swapToTenantEmailIfNeeded(userId);

    if (swapResult.swapped) {
      console.log(`beginSetup: email swapped to ${swapResult.newEmail}`);
    } else {
      console.log('beginSetup: no swap needed (already correct or no tenantEmail attribute)');
    }
  } catch (err) {
    // Log but don't fail - let user continue to Keycloak
    console.error('beginSetup: swap failed (continuing anyway):', err.message);
  }

  // Redirect to the original Keycloak action link
  console.log(`beginSetup: redirecting to Keycloak`);
  res.redirect(302, next);
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
    console.error('Recovery error:', error);
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

// Guest complete - redirect to the document after passkey registration
app.get('/guest-complete', (req, res) => {
  const { doc } = req.query;
  if (doc) {
    const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
    return res.redirect(`${docsHost}/docs/${encodeURIComponent(doc)}/`);
  }
  // Fallback: go to the main docs page
  const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
  res.redirect(docsHost || '/');
});

// Guest landing - smart redirect based on whether user exists
app.get('/guest-landing', async (req, res) => {
  const { email, doc } = req.query;

  if (!email || !doc) {
    return res.redirect('/register');
  }

  try {
    const existingUser = await keycloakApi.findUserByEmail(email.toLowerCase());
    if (existingUser) {
      // User exists - send them to the doc (which triggers Keycloak login)
      const docsHost = (process.env.BASE_URL || '').replace('account.', 'docs.');
      return res.redirect(`${docsHost}/docs/${encodeURIComponent(doc)}/`);
    }
  } catch (err) {
    console.error('Guest landing lookup error:', err.message);
  }

  // User doesn't exist - send them to registration
  res.redirect(`/register?email=${encodeURIComponent(email)}&doc=${encodeURIComponent(doc)}`);
});

app.get('/register', (req, res) => {
  const email = req.query.email || '';
  const doc = req.query.doc || '';

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
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
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

    const { doc } = req.body;

    // Build the redirect URL - must be within account portal domain (Keycloak redirect_uri validation)
    let redirectAfterSetup = process.env.BASE_URL || '';
    if (doc) {
      redirectAfterSetup = `${process.env.BASE_URL}/guest-complete?doc=${encodeURIComponent(doc)}`;
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
    console.error('Guest registration error:', error);
    res.status(500).json({ error: error.message });
  }
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
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
