import http from 'k6/http';
import { check, sleep } from 'k6';
import { buildOptions } from '../common/thresholds.js';
import { loadUsers, selectUser } from '../common/users.js';
import { getKeycloakToken } from './auth.js';

export const options = Object.assign({}, buildOptions('docs'), {
  vus: 1,
  duration: '1m',
});

const FRONTEND = __ENV.DOCS_FRONTEND_BASE_URL || '';
const BACKEND = __ENV.DOCS_BACKEND_BASE_URL || '';
const PROTECTED_PATH = __ENV.DOCS_PROTECTED_PATH || '';
const USES_CSV = !!(__ENV.USERS_CSV_PATH || __ENV.USERS_CSV_INLINE);
const USERS = USES_CSV ? loadUsers() : null;

export default function () {
  if (FRONTEND) {
    const r1 = http.get(FRONTEND);
    check(r1, { 'frontend 200': (r) => r.status === 200 });
  }
  if (BACKEND) {
    const r2 = http.get(`${BACKEND}/health`);
    check(r2, { 'backend health ok': (r) => r.status === 200 });
  }
  if (BACKEND && PROTECTED_PATH && USES_CSV) {
    const u = selectUser(USERS);
    const token = getKeycloakToken(u.username, u.password);
    if (token) {
      const r3 = http.get(`${BACKEND}${PROTECTED_PATH}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      check(r3, { 'protected ok': (r) => r.status === 200 });
    }
  }
  sleep(1);
}



