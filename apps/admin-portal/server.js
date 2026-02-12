const express = require('express');
const session = require('express-session');
const passport = require('passport');
const helmet = require('helmet');
const path = require('path');
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

// Initialize OIDC
async function initializeOIDC() {
  const issuerUrl = process.env.KEYCLOAK_ISSUER;
  const clientId = process.env.KEYCLOAK_CLIENT_ID;
  const clientSecret = process.env.KEYCLOAK_CLIENT_SECRET;
  const callbackUrl = `${process.env.BASE_URL}/auth/callback`;
  const bootstrapCallbackUrl = `${process.env.BASE_URL}/bootstrap/callback`;

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

app.get('/auth/login', passport.authenticate('oidc', { scope: 'openid email profile' }));

app.get('/auth/callback',
  passport.authenticate('oidc', { failureRedirect: '/auth/error' }),
  (req, res) => {
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

app.post('/api/invite', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const { firstName, lastName, email, recoveryEmail } = req.body;

    if (!firstName || !lastName || !email || !recoveryEmail) {
      return res.status(400).json({ error: 'All fields are required' });
    }

    // Create user in Keycloak
    const result = await keycloakApi.createUser({
      firstName,
      lastName,
      email,
      recoveryEmail,
    });

    // Send invitation email
    await keycloakApi.sendInvitationEmail(result.userId);

    res.json({ success: true, userId: result.userId });
  } catch (error) {
    console.error('Invite error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.get('/api/users', requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    const users = await keycloakApi.listUsers();
    res.json(users);
  } catch (error) {
    console.error('List users error:', error);
    res.status(500).json({ error: error.message });
  }
});

app.delete('/api/users/:id', verifyOrigin, requireAuth, requireTenantAdmin, async (req, res) => {
  try {
    await keycloakApi.deleteUser(req.params.id);
    res.json({ success: true });
  } catch (error) {
    console.error('Delete user error:', error);
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
    res.redirect('/dashboard');
  }
);

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
      console.log(`Admin Portal running on port ${PORT}`);
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

start();
