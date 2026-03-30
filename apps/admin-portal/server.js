const express = require('express');
const session = require('express-session');
const passport = require('passport');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const path = require('path');
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

// Rate limiting - defaults: 100 req/5min, configurable via env vars
app.use(rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS, 10) || 5 * 60 * 1000,
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
    prefix: 'admin-portal:sess:',
  });
  console.log(`Redis: Session store configured (${redisHost}:${redisPort})`);
} else {
  console.warn('WARNING: REDIS_HOST not set - using in-memory sessions (not HA-safe)');
  console.warn('WARNING: With multiple replicas, OIDC login will fail randomly');
}

// Compute shared cookie domain from BASE_URL (e.g., https://admin.dev.example.com -> .dev.example.com)
// This allows logout from one portal to clear cookies for both admin and account portals
const cookieDomain = (() => {
  try {
    const host = new URL(process.env.BASE_URL).hostname;
    // Strip first subdomain (admin.) to get shared parent domain
    const parts = host.split('.');
    return parts.length > 2 ? '.' + parts.slice(1).join('.') : undefined;
  } catch { return undefined; }
})();

// Session - must be configured correctly for OIDC callback to work
// sameSite: 'lax' permits GET navigations from cross-origin (OIDC redirects are GET)
app.use(session({
  name: 'admin.sid',        // Unique cookie name (account portal uses 'account.sid')
  store: sessionStore,      // Redis store for HA, undefined falls back to MemoryStore
  secret: process.env.SESSION_SECRET,
  resave: false,            // Don't save session if unmodified (Redis handles expiry)
  saveUninitialized: false, // Don't create session until something is stored
  cookie: {
    domain: cookieDomain,   // Shared parent domain so logout clears both portals
    secure: process.env.NODE_ENV !== 'development',
    httpOnly: true,
    sameSite: process.env.NODE_ENV === 'development' ? false : 'lax',
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

// Initialize OIDC
async function initializeOIDC() {
  const issuerUrl = process.env.KEYCLOAK_ISSUER;
  const internalUrl = process.env.KEYCLOAK_INTERNAL_URL;
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  const clientSecret = process.env.KEYCLOAK_CLIENT_SECRET;
  const callbackUrl = `${process.env.BASE_URL}/auth/callback`;
  const bootstrapCallbackUrl = `${process.env.BASE_URL}/bootstrap/callback`;

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
        tokenExpiresAt: tokenSet.expires_at, // Unix timestamp (seconds)
      };
      return done(null, user);
    }
  ));

  // Bootstrap client - uses standard browser flow (password + required actions)
  const bootstrapClientId = process.env.KEYCLOAK_BOOTSTRAP_CLIENT_ID || 'admin-portal-bootstrap';
  const bootstrapClientSecret = process.env.KEYCLOAK_BOOTSTRAP_CLIENT_SECRET || clientSecret;

  const bootstrapClient = new keycloakIssuer.Client({
    client_id: bootstrapClientId,
    client_secret: bootstrapClientSecret,
    redirect_uris: [bootstrapCallbackUrl],
    response_types: ['code'],
  });

  passport.use('oidc-bootstrap', new Strategy(
    { client: bootstrapClient, passReqToCallback: true },
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
      // Don't block the request — let it proceed with the old token
      // The next auth-required request will redirect to login if truly expired
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

function requireTenantAdmin(req, res, next) {
  if (req.isAuthenticated() && req.user.roles.includes('tenant-admin')) {
    return next();
  }
  res.status(403).render('error', {
    title: 'Access Denied',
    message: 'You need the tenant-admin role to access this page.'
  });
}

// Routes
app.get('/', (req, res) => {
  if (req.isAuthenticated()) {
    return res.redirect('/dashboard');
  }
  res.render('home', { title: 'MotherTree Admin Portal' });
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
  (req, res) => {
    // Ensure passkey is ordered before password (non-blocking)
    if (req.user?.id) {
      keycloakApi.ensurePasskeyFirst(req.user.id).catch(err =>
        console.error('ensurePasskeyFirst failed on login:', err.message)
      );
    }
    res.redirect('/dashboard');
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

app.get('/dashboard', requireAuth, requireTenantAdmin, (req, res) => {
  res.render('dashboard', {
    title: 'Dashboard',
    user: req.user
  });
});

// API Routes
const keycloakApi = require('./api/keycloak');
const stalwartApi = require('./api/stalwart');
const synapseApi = require('./api/synapse');

app.post('/api/invite', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const { firstName, lastName, email, recoveryEmail } = req.body;

    if (!firstName || !lastName || !email || !recoveryEmail) {
      return res.status(400).json({ error: 'All fields are required' });
    }

    // Step 1: Create user in Keycloak (fatal — must succeed)
    const result = await keycloakApi.createUser({
      firstName,
      lastName,
      email,
      recoveryEmail,
    });

    // Step 2: Send invitation email (fatal — moved before service provisioning
    // so the user gets their invite even if downstream services fail)
    await keycloakApi.sendInvitationEmail(result.userId);

    // Respond immediately — the critical path (Keycloak + email) is done.
    // Downstream provisioning runs in the background so it doesn't block the
    // HTTP response (Stalwart and Synapse can take 10+ seconds under load).
    res.json({ success: true, userId: result.userId });

    // Step 3: Provision Stalwart email account (non-fatal, background)
    const displayName = `${firstName} ${lastName}`;
    stalwartApi.ensureUserExists(email, displayName, parseInt(process.env.DEFAULT_EMAIL_QUOTA_MB || '5120', 10) * 1024 * 1024)
      .catch(err => console.error('Stalwart provisioning failed (non-fatal):', err.message));

    // Step 4: Provision Matrix/Synapse account (non-fatal, background)
    synapseApi.ensureMatrixUser(email, displayName)
      .catch(err => console.error('Synapse provisioning failed (non-fatal):', err.message));
  } catch (error) {
    console.error('Invite error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/users', requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const users = await keycloakApi.listUsers();
    // Enrich with email quota from Stalwart
    const enriched = await Promise.all(users.map(async (user) => {
      try {
        const { quota } = await stalwartApi.getUserQuota(user.email);
        user.quotaMb = quota > 0 ? Math.round(quota / (1024 * 1024)) : 0;
      } catch {
        user.quotaMb = 0;
      }
      return user;
    }));
    res.json(enriched);
  } catch (error) {
    console.error('List users error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.delete('/api/users/:id', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    await keycloakApi.deleteUser(req.params.id);
    res.json({ success: true });
  } catch (error) {
    console.error('Delete user error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.put('/api/users/:email/quota', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const { quotaMb } = req.body;
    if (quotaMb === undefined || quotaMb === null || quotaMb < 0) {
      return res.status(400).json({ error: 'quotaMb is required and must be >= 0' });
    }
    const quotaBytes = Math.round(quotaMb) * 1024 * 1024;
    await stalwartApi.setUserQuota(req.params.email, quotaBytes);
    res.json({ success: true });
  } catch (error) {
    console.error('Set quota error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

app.post('/api/quota/backfill', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const defaultQuotaMb = parseInt(process.env.DEFAULT_EMAIL_QUOTA_MB || '5120', 10);
    const defaultQuotaBytes = defaultQuotaMb * 1024 * 1024;
    const result = await stalwartApi.backfillQuotas(defaultQuotaBytes);
    res.json(result);
  } catch (error) {
    console.error('Backfill quotas error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

// Bootstrap login - uses a separate OIDC client with standard browser flow
// This allows password login + required actions (passkey registration)
app.get('/bootstrap', (req, res, next) => {
  if (req.isAuthenticated()) {
    return res.redirect('/dashboard');
  }
  // Ensure session is saved before OIDC redirect (important for long passkey registration)
  req.session.save((err) => {
    if (err) console.error('Session save error:', err);
    passport.authenticate('oidc-bootstrap', { scope: 'openid email profile' })(req, res, next);
  });
});

app.get('/bootstrap/callback',
  passport.authenticate('oidc-bootstrap', { failureRedirect: '/auth/error' }),
  (req, res) => {
    // Bootstrap admins get a password first, then register a passkey.
    // Reorder so the passkey takes priority on next login (non-blocking).
    if (req.user?.id) {
      keycloakApi.ensurePasskeyFirst(req.user.id).catch(err =>
        console.error('ensurePasskeyFirst failed on bootstrap:', err.message)
      );
    }
    res.redirect('/dashboard');
  }
);

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
      console.log(`Admin Portal running on port ${PORT}`);
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

start();
