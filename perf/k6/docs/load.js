import http from 'k6/http';
import { check, sleep } from 'k6';
import { buildOptions } from '../common/thresholds.js';
import { loadUsers, selectUser } from '../common/users.js';
import { getKeycloakToken } from './auth.js';
import { createDocument, updateDocument, getDocument } from './documents.js';

export const options = Object.assign({}, buildOptions('docs'), {
  scenarios: {
    steady_load: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 200,
      stages: [
        { target: 50, duration: '3m' },
        { target: 100, duration: '5m' },
        { target: 150, duration: '5m' },
        { target: 0, duration: '1m' },
      ],
    },
  },
});

const FRONTEND = __ENV.DOCS_FRONTEND_BASE_URL || '';
const BACKEND = __ENV.DOCS_BACKEND_BASE_URL || '';
const PROTECTED_PATH = __ENV.DOCS_PROTECTED_PATH || '';
const USES_CSV = !!(__ENV.USERS_CSV_PATH || __ENV.USERS_CSV_INLINE);
const USERS = USES_CSV ? loadUsers() : null;
const ENABLE_DOCUMENT_EDITING = __ENV.DOCS_ENABLE_DOCUMENT_EDITING !== '0'; // Default to true if not explicitly disabled

export default function () {
  if (FRONTEND) {
    const r1 = http.get(FRONTEND);
    check(r1, { 'frontend ok': (r) => r.status === 200 });
  }
  if (BACKEND) {
    const r2 = http.get(`${BACKEND}/health`);
    check(r2, { 'backend health ok': (r) => r.status === 200 });
  }
  
  // Authenticated operations (require CSV users)
  if (BACKEND && USES_CSV) {
    const u = selectUser(USERS);
    const token = getKeycloakToken(u.username, u.password);
    if (token) {
      // Test protected endpoint if configured
      if (PROTECTED_PATH) {
        const r3 = http.get(`${BACKEND}${PROTECTED_PATH}`, {
          headers: { Authorization: `Bearer ${token}` },
        });
        check(r3, { 'protected ok': (r) => r.status === 200 });
      }
      
      // Document editing operations
      if (ENABLE_DOCUMENT_EDITING) {
        // Create a new document
        const doc = createDocument(BACKEND, token, {
          title: `Load Test Doc VU${__VU} Iter${__ITER}`,
          content: `Initial content created at ${new Date().toISOString()}`,
        });
        
        if (doc && doc.id) {
          // Update the document
          const updateSuccess = updateDocument(BACKEND, token, doc.id, {
            content: `Updated content at ${new Date().toISOString()} by VU${__VU}`,
          });
          
          if (updateSuccess) {
            // Optionally retrieve to verify
            const retrieved = getDocument(BACKEND, token, doc.id);
            check(retrieved !== null, { 'document retrieved after update': () => retrieved !== null });
          }
        }
      }
    }
  }
  sleep(1);
}



