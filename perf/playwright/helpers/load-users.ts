/**
 * Load test user pool.
 *
 * Users are named load-01 through load-20, all with the same password.
 * Each Playwright worker picks a unique user by workerIndex.
 */

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const userCount = Number(process.env.LOAD_USER_COUNT || 20);
const password = 'load-testpass';

export interface LoadUser {
  username: string;
  password: string;
  email: string;
  index: number;
}

function buildUsers(count: number): LoadUser[] {
  const users: LoadUser[] = [];
  for (let i = 1; i <= count; i++) {
    const padded = String(i).padStart(2, '0');
    users.push({
      username: `load-${padded}`,
      password,
      email: `load-${padded}@${baseDomain}`,
      index: i,
    });
  }
  return users;
}

export const LOAD_USERS = buildUsers(userCount);

/** Get the user assigned to this worker. */
export function getUserForWorker(workerIndex: number): LoadUser {
  const user = LOAD_USERS[workerIndex % LOAD_USERS.length];
  if (!user) {
    throw new Error(`No user for workerIndex ${workerIndex} (only ${LOAD_USERS.length} users)`);
  }
  return user;
}
