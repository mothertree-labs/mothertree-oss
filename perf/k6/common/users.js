// Shared CSV user loader for k6
// Sources:
// - USERS_CSV_PATH: file path accessible to k6/open()
// - USERS_CSV_INLINE: base64-encoded CSV content ("username,password" per line)
//
// Selection policy:
// - Per-VU assignment by default: user index = (__VU - 1) % users.length
// - Optional per-iteration round-robin when USERS_ROUND_ROBIN=1
//
// Guardrails:
// - If K6_VUS > users.length and USERS_ALLOW_REUSE!=1, fail early

import { SharedArray } from 'k6/data';
import encoding from 'k6/encoding';
import { fail } from 'k6';

function parseCsv(raw) {
  const lines = raw
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith('#'));
  const entries = lines.map((line, idx) => {
    const parts = line.split(',');
    if (parts.length < 2) {
      fail(`Malformed CSV at line ${idx + 1}: expected "username,password"`);
    }
    const username = (parts[0] || '').trim();
    const password = (parts[1] || '').trim();
    if (!username || !password) {
      fail(`Invalid CSV at line ${idx + 1}: username/password cannot be empty`);
    }
    return { username, password };
  });
  if (entries.length === 0) {
    fail('CSV contained no users');
  }
  return entries;
}

export function loadUsers() {
  const fromPath = __ENV.USERS_CSV_PATH ? open(__ENV.USERS_CSV_PATH) : '';
  const fromInline = __ENV.USERS_CSV_INLINE
    ? encoding.b64decode(__ENV.USERS_CSV_INLINE, 'rawstd', 's')
    : '';
  const raw = (fromPath || fromInline || '').trim();
  if (!raw) {
    fail('USERS_CSV_PATH or USERS_CSV_INLINE must be set');
  }
  const users = new SharedArray('users', () => parseCsv(raw));

  const vus = Number(__ENV.K6_VUS || __ENV.VUS || 0);
  const allowReuse = __ENV.USERS_ALLOW_REUSE === '1';
  if (vus > 0 && users.length > 0 && vus > users.length && !allowReuse) {
    fail(
      `Not enough users for VUs: vus=${vus} > users=${users.length}. ` +
        'Either reduce VUs, provide more users, or set USERS_ALLOW_REUSE=1.'
    );
  }
  return users;
}

export function selectUser(users) {
  const roundRobin = __ENV.USERS_ROUND_ROBIN === '1';
  if (!roundRobin) {
    // Per-VU assignment
    return users[(__VU - 1) % users.length];
  }
  // Round-robin per iteration across all users
  const idx = (__ITER + (__VU - 1)) % users.length;
  return users[idx];
}


