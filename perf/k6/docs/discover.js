// API Discovery Script for Docs Backend
// This script attempts to discover the actual API endpoints by testing common patterns

import http from 'k6/http';
import { check } from 'k6';
import { getKeycloakToken } from './auth.js';
import { loadUsers, selectUser } from '../common/users.js';

export const options = {
  vus: 1,
  iterations: 1,
};

const BACKEND = __ENV.DOCS_BACKEND_BASE_URL || '';
const USES_CSV = !!(__ENV.USERS_CSV_PATH || __ENV.USERS_CSV_INLINE);
const USERS = USES_CSV ? loadUsers() : null;
const API_BASE = __ENV.DOCS_API_BASE || '/api/v1.0';

// Common endpoint patterns to test
const ENDPOINTS_TO_TEST = [
  // API root/discovery
  { method: 'GET', path: `${API_BASE}/`, description: 'API root' },
  { method: 'GET', path: `${API_BASE}`, description: 'API base (no trailing slash)' },
  
  // Document endpoints (common Django REST patterns)
  { method: 'GET', path: `${API_BASE}/documents/`, description: 'List documents' },
  { method: 'GET', path: `${API_BASE}/documents`, description: 'List documents (no trailing slash)' },
  { method: 'GET', path: `${API_BASE}/document/`, description: 'List documents (singular)' },
  { method: 'GET', path: `${API_BASE}/docs/`, description: 'List docs (short form)' },
  { method: 'GET', path: `${API_BASE}/pages/`, description: 'List pages' },
  { method: 'GET', path: `${API_BASE}/files/`, description: 'List files' },
  
  // User/profile endpoints
  { method: 'GET', path: `${API_BASE}/user/`, description: 'Current user' },
  { method: 'GET', path: `${API_BASE}/users/`, description: 'List users' },
  { method: 'GET', path: `${API_BASE}/me/`, description: 'Current user (me)' },
  { method: 'GET', path: `${API_BASE}/profile/`, description: 'User profile' },
  
  // Workspace/space endpoints
  { method: 'GET', path: `${API_BASE}/workspaces/`, description: 'List workspaces' },
  { method: 'GET', path: `${API_BASE}/spaces/`, description: 'List spaces' },
  { method: 'GET', path: `${API_BASE}/workspace/`, description: 'Workspace (singular)' },
  
  // Other common patterns
  { method: 'GET', path: `${API_BASE}/collections/`, description: 'List collections' },
  { method: 'GET', path: `${API_BASE}/folders/`, description: 'List folders' },
];

export default function () {
  if (!BACKEND) {
    console.error('DOCS_BACKEND_BASE_URL not set');
    return;
  }

  let token = '';
  if (USES_CSV && USERS && USERS.length > 0) {
    const u = selectUser(USERS);
    token = getKeycloakToken(u.username, u.password);
    if (!token) {
      console.error('Failed to get authentication token');
      return;
    }
    console.log(`Authenticated as user: ${u.username}`);
  } else {
    console.log('No CSV users available, testing unauthenticated endpoints only');
  }

  console.log(`\n=== Testing API Endpoints on ${BACKEND} ===\n`);

  const results = {
    authenticated: [],
    unauthenticated: [],
    errors: [],
  };

  for (const endpoint of ENDPOINTS_TO_TEST) {
    const url = `${BACKEND}${endpoint.path}`;
    const headers = token ? { Authorization: `Bearer ${token}` } : {};

    const res = http.request(endpoint.method, url, null, { headers });

    const result = {
      method: endpoint.method,
      path: endpoint.path,
      url: url,
      status: res.status,
      description: endpoint.description,
      authenticated: !!token,
    };

    // Categorize results
    if (res.status >= 200 && res.status < 300) {
      // Success
      if (token) {
        results.authenticated.push(result);
      } else {
        results.unauthenticated.push(result);
      }
      console.log(`✅ ${endpoint.method} ${endpoint.path} -> ${res.status} (${endpoint.description})`);
      
      // Try to parse response for hints
      try {
        const body = res.json();
        if (body && typeof body === 'object') {
          console.log(`   Response keys: ${Object.keys(body).join(', ')}`);
          if (body.results) {
            console.log(`   Has 'results' array (likely paginated list)`);
          }
          if (body.id) {
            console.log(`   Has 'id' field (likely single resource)`);
          }
        }
      } catch (e) {
        // Not JSON, that's ok
      }
    } else if (res.status === 401 || res.status === 403) {
      // Auth required
      if (!token) {
        results.unauthenticated.push({ ...result, note: 'Requires authentication' });
        console.log(`🔒 ${endpoint.method} ${endpoint.path} -> ${res.status} (${endpoint.description}) - Requires auth`);
      } else {
        results.errors.push({ ...result, note: 'Auth failed or insufficient permissions' });
        console.log(`❌ ${endpoint.method} ${endpoint.path} -> ${res.status} (${endpoint.description}) - Auth issue`);
      }
    } else if (res.status === 404) {
      // Not found
      console.log(`⚪ ${endpoint.method} ${endpoint.path} -> 404 (${endpoint.description})`);
    } else if (res.status === 405) {
      // Method not allowed (endpoint exists but wrong method)
      results.unauthenticated.push({ ...result, note: 'Method not allowed (endpoint exists)' });
      console.log(`⚠️  ${endpoint.method} ${endpoint.path} -> 405 (${endpoint.description}) - Endpoint exists but method not allowed`);
    } else {
      // Other error
      results.errors.push(result);
      console.log(`❌ ${endpoint.method} ${endpoint.path} -> ${res.status} (${endpoint.description})`);
    }
  }

  // Summary
  console.log(`\n=== Discovery Summary ===`);
  console.log(`✅ Successful authenticated endpoints: ${results.authenticated.length}`);
  console.log(`✅ Successful unauthenticated endpoints: ${results.unauthenticated.length}`);
  console.log(`❌ Errors: ${results.errors.length}`);

  if (results.authenticated.length > 0) {
    console.log(`\n=== Working Authenticated Endpoints ===`);
    results.authenticated.forEach(r => {
      console.log(`${r.method} ${r.path} (${r.status})`);
    });
  }

  if (results.unauthenticated.length > 0) {
    console.log(`\n=== Working Unauthenticated Endpoints ===`);
    results.unauthenticated.forEach(r => {
      console.log(`${r.method} ${r.path} (${r.status})${r.note ? ' - ' + r.note : ''}`);
    });
  }

  // Test creating a document if we found a documents endpoint
  const documentsEndpoint = results.authenticated.find(r => 
    r.path.includes('document') || r.path.includes('doc') || r.path.includes('page')
  );

  if (documentsEndpoint && token) {
    console.log(`\n=== Testing Document Creation ===`);
    const createUrl = `${BACKEND}${documentsEndpoint.path}`;
    const createPayload = JSON.stringify({
      title: 'Discovery Test Document',
      content: 'This is a test document created by the discovery script',
    });

    const createRes = http.post(createUrl, createPayload, {
      headers: {
        'Authorization': `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    });

    if (createRes.status === 201 || createRes.status === 200) {
      console.log(`✅ Successfully created document! Status: ${createRes.status}`);
      try {
        const doc = createRes.json();
        console.log(`   Document ID: ${doc.id || doc.pk || 'unknown'}`);
        console.log(`   Response structure: ${JSON.stringify(Object.keys(doc))}`);
        
        // Try to update it
        if (doc.id || doc.pk) {
          const docId = doc.id || doc.pk;
          const updateUrl = `${BACKEND}${documentsEndpoint.path}${docId}/`;
          const updatePayload = JSON.stringify({
            content: 'Updated content from discovery script',
          });
          
          const updateRes = http.patch(updateUrl, updatePayload, {
            headers: {
              'Authorization': `Bearer ${token}`,
              'Content-Type': 'application/json',
            },
          });
          
          if (updateRes.status === 200 || updateRes.status === 204) {
            console.log(`✅ Successfully updated document! Status: ${updateRes.status}`);
          } else {
            console.log(`❌ Update failed: ${updateRes.status}`);
          }
        }
      } catch (e) {
        console.log(`   Could not parse response: ${e.message}`);
      }
    } else {
      console.log(`❌ Create failed: ${createRes.status}`);
      console.log(`   Response: ${createRes.body.substring(0, 200)}`);
    }
  }
}









