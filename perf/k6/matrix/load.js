import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { buildOptions } from '../common/thresholds.js';
import { loadUsers, selectUser } from '../common/users.js';

const VUS = Number(__ENV.K6_VUS || 20);
const DURATION = __ENV.K6_DURATION || '5m';
const LOG_ALL_ERRORS = __ENV.K6_LOG_ALL_ERRORS === '1';

const baseOptions = buildOptions('matrix');
export const options = Object.assign({}, baseOptions, {
  scenarios: {
    load: {
      executor: 'constant-vus',
      vus: VUS,
      duration: DURATION,
    },
  },
  // Hard fail when no traffic or key checks fail
  thresholds: Object.assign({}, baseOptions.thresholds || {}, {
    'http_reqs': ['count>0'],
    'checks{check:login_ok}': ['rate==1'],
    'checks{check:sync_ok}': ['rate>0.95'],
  }),
});

const MATRIX = __ENV.MATRIX_BASE_URL || '';
const ACCESS_TOKEN = __ENV.MATRIX_ACCESS_TOKEN || '';
const USER = __ENV.MATRIX_USER || '';
const PASSWORD = __ENV.MATRIX_PASSWORD || '';
const ROOM_ID = __ENV.MATRIX_ROOM_ID || '';
const MATRIX_DOMAIN = __ENV.MATRIX_DOMAIN || '';
const USES_CSV = !!(__ENV.USERS_CSV_PATH || __ENV.USERS_CSV_INLINE);
const USERS = USES_CSV ? loadUsers() : null;

// Extract domain from ROOM_ID if MATRIX_DOMAIN not set
// Room ID format: !room:matrix.dev.example.com -> use that domain
let DOMAIN = MATRIX_DOMAIN;
if (!DOMAIN && ROOM_ID) {
  // Extract domain from room ID (everything after the colon)
  DOMAIN = ROOM_ID.split(':').pop();
}
// Default fallback - should match server_name from Synapse config
if (!DOMAIN) {
  DOMAIN = 'matrix.dev.example.com';
}

export function setup() {
  if (!MATRIX) {
    fail('Missing MATRIX_BASE_URL');
  }
  if (!USES_CSV && !ACCESS_TOKEN && (!USER || !PASSWORD)) {
    fail('Missing MATRIX_ACCESS_TOKEN or MATRIX_USER/PASSWORD (or USERS_CSV_*)');
  }
  if (!ROOM_ID) {
    fail('MATRIX_ROOM_ID must be set - room is required for this test');
  }
}

function shouldLogError() {
  if (LOG_ALL_ERRORS) return true;
  // sample logs to avoid overwhelming output
  return (__VU % 10 === 0) && (__ITER % 10 === 0);
}

function logHttpError(kind, res) {
  if (!shouldLogError()) return;
  if (!res) {
    console.error(`[${kind}] no response object`);
    return;
  }
  if (res.error) {
    console.error(`[${kind}] transport error: ${res.error} code=${res.error_code || ''}`);
    return;
  }
  const body = typeof res.body === 'string' ? res.body.slice(0, 300) : '';
  console.error(`[${kind}] status=${res.status} body=${body}`);
}

function loginWithCredentials(username, password) {
  const maxRetries = 3;
  let retryCount = 0;
  
  // Build list of username formats to try
  // Based on testing: username-only format works, full MXID may not always work
  // So try username first, then full MXID
  const usernameFormats = [];
  if (username.startsWith('@')) {
    // Already in MXID format, use as-is
    usernameFormats.push(username);
  } else {
    // Try username first (this format works based on testing)
    usernameFormats.push(username);
    // Then try full MXID format
    if (DOMAIN) {
      usernameFormats.push(`@${username}:${DOMAIN}`);
    }
  }
  
  // Try each username format
  for (let formatIdx = 0; formatIdx < usernameFormats.length; formatIdx++) {
    const loginUsername = usernameFormats[formatIdx];
    retryCount = 0;
    
    while (retryCount < maxRetries) {
      console.log(`[login] Attempting login for user: ${username} (format: ${loginUsername}, attempt: ${retryCount + 1}/${maxRetries})`);
      
      const res = http.post(`${MATRIX}/_matrix/client/v3/login`, JSON.stringify({
        type: 'm.login.password',
        identifier: { type: 'm.id.user', user: loginUsername },
        password: password,
      }), { headers: { 'Content-Type': 'application/json' } });
      
      if (res.status === 200) {
        const token = res.json('access_token') || '';
        if (!token) {
          fail(`Login succeeded but no access_token returned for user ${username} (tried as ${loginUsername})`);
        }
        return token;
      }
      
      // Handle rate limiting (429) - retry after the specified delay
      if (res.status === 429) {
        const body = typeof res.body === 'string' ? res.body : '';
        let retryAfter = 5000; // Default 5 seconds
        
        // Try to extract retry_after_ms from response
        try {
          const jsonBody = JSON.parse(body);
          if (jsonBody.retry_after_ms) {
            retryAfter = Math.min(jsonBody.retry_after_ms, 60000); // Cap at 60 seconds
          }
        } catch (e) {
          // If parsing fails, use default
        }
        
        retryCount++;
        if (retryCount >= maxRetries) {
          logHttpError('login', res);
          fail(`Login failed for user ${username} (tried as ${loginUsername}) after ${maxRetries} retries: rate limited (429) - retry_after_ms=${retryAfter}`);
        }
        
        console.log(`[login] Rate limited for user ${username} (format: ${loginUsername}), retrying after ${retryAfter}ms`);
        // Wait before retrying
        sleep(retryAfter / 1000);
        continue;
      }
      
      // For 403 errors, try next username format if available
      if (res.status === 403) {
        console.log(`[login] 403 Forbidden for user ${username} (format: ${loginUsername}), trying next format...`);
        break; // Break out of retry loop, try next format
      }
      
      // For all other errors, fail immediately
      logHttpError('login', res);
      fail(`Login failed for user ${username} (tried as ${loginUsername}): status=${res.status} body=${typeof res.body === 'string' ? res.body.slice(0, 200) : ''}`);
      return '';
    }
  }
  
  // If we've tried all formats and all failed, fail with details
  fail(`Login failed for user ${username} after trying all formats: ${usernameFormats.join(', ')}. Last error: 403 Forbidden - Invalid username or password`);
  return '';
}

function joinRoom(token, roomId) {
  const res = http.post(`${MATRIX}/_matrix/client/v3/join/${encodeURIComponent(roomId)}`, 
    JSON.stringify({}), 
    { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } });
  // 200 = success, 403 = already joined (treat as success)
  if (res.status === 200) {
    return true;
  }
  if (res.status === 403) {
    // Check if it's "already joined" vs "forbidden"
    const body = typeof res.body === 'string' ? res.body : '';
    if (body.includes('already_joined') || body.includes('Already in room')) {
      return true; // Already joined, that's fine
    }
    // Otherwise it's a real forbidden error
    logHttpError('join', res);
    fail(`Unable to join room ${roomId}: 403 Forbidden - user may not have permission`);
    return false;
  }
  logHttpError('join', res);
  fail(`Unable to join room ${roomId}: status=${res.status} body=${typeof res.body === 'string' ? res.body.slice(0, 200) : ''}`);
  return false;
}

export default function () {
  if (!MATRIX) { 
    fail('MATRIX_BASE_URL not set');
    return;
  }
  
  // Login - fail hard on any error
  let token = '';
  if (ACCESS_TOKEN) {
    token = ACCESS_TOKEN;
    if (!token) {
      fail('MATRIX_ACCESS_TOKEN is empty');
    }
  } else if (USES_CSV) {
    const u = selectUser(USERS);
    token = loginWithCredentials(u.username, u.password);
    // loginWithCredentials will fail() if login fails, so if we get here token should be valid
  } else {
    token = loginWithCredentials(USER, PASSWORD);
    // loginWithCredentials will fail() if login fails, so if we get here token should be valid
  }
  
  if (!token) {
    fail('No access token available after login attempt');
  }

  // Sync to establish session
  const sync = http.get(`${MATRIX}/_matrix/client/v3/sync`, { headers: { Authorization: `Bearer ${token}` } });
  const okSync = check(sync, { 'sync_ok': (r) => r.status === 200 });
  if (!okSync) {
    logHttpError('sync', sync);
    fail(`Sync failed: status=${sync.status} body=${typeof sync.body === 'string' ? sync.body.slice(0, 200) : ''}`);
  }

  // Room operations - fail hard on any error
  if (!ROOM_ID) {
    fail('MATRIX_ROOM_ID not set - room is required');
  }

  // Join room before sending - fail hard if unable to join
  const joined = joinRoom(token, ROOM_ID);
  if (!joined) {
    // joinRoom will fail() if join fails, but check anyway
    fail(`Failed to join room ${ROOM_ID}`);
  }

  for (let i = 0; i < 10; i++) {   
    // Send message to room - fail hard on any error
    const txnId = Math.random().toString(36).slice(2);
    const send = http.put(`${MATRIX}/_matrix/client/v3/rooms/${encodeURIComponent(ROOM_ID)}/send/m.room.message/${txnId}`,
      JSON.stringify({ msgtype: 'm.text', body: `perf test (vu=${__VU}, iter=${__ITER}, msg=${i})` }),
      { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } });
    
    sleep(Math.random() * 0.05); // sleep for 0.05 to 0.1 seconds
      
    if (send.status < 200 || send.status >= 300) {
      logHttpError('send', send);
      fail(`Send message failed: status=${send.status} body=${typeof send.body === 'string' ? send.body.slice(0, 200) : ''}`);
    }
  }
} 



