import { execSync } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

const REPO_ROOT = path.resolve(__dirname, '..');
const SCRIPT = path.join(REPO_ROOT, 'scripts', 'dev-test-users.sh');
const TENANT = process.env.E2E_TENANT || 'example';
const IS_CI = !!process.env.CI || !!process.env.BUILDKITE;

interface TestUser {
  username: string;
  password: string;
  admin?: boolean;
}

const TEST_USERS: TestUser[] = [
  { username: 'e2e-admin', password: 'e2e-testpass-admin', admin: true },
  { username: 'e2e-member', password: 'e2e-testpass-member' },
  { username: 'e2e-email-test1', password: 'e2e-testpass-email' },
];

function run(cmd: string): string {
  console.log(`  [setup] ${cmd}`);
  return execSync(cmd, {
    cwd: REPO_ROOT,
    encoding: 'utf-8',
    timeout: 60_000,
    env: { ...process.env, PATH: process.env.PATH },
  });
}

export default async function globalSetup(): Promise<void> {
  console.log('\n[E2E Global Setup]\n');

  // Clear and recreate .auth directory to force fresh logins
  // (stale cookies from previous runs cause silent auth failures)
  const authDir = path.join(__dirname, '.auth');
  if (fs.existsSync(authDir)) {
    fs.rmSync(authDir, { recursive: true });
  }
  fs.mkdirSync(authDir, { recursive: true });

  // In CI, test users are pre-created and permanent — no Keycloak admin access needed.
  // Locally, create/reset users via dev-test-users.sh (requires kubectl port-forward).
  if (IS_CI) {
    console.log('  [setup] CI detected — skipping user management (users are pre-provisioned)\n');
    return;
  }

  console.log('  [setup] Local run — managing test users via Keycloak admin API...\n');

  // Clean up stale e2e-invite-* users from previous failed test runs
  try {
    const listOutput = run(
      `${SCRIPT} -e dev -t ${TENANT} list`,
    );
    const staleUsers = listOutput
      .split('\n')
      .map((line) => line.trim().split(/\s+/)[0])
      .filter((username) => username?.startsWith('e2e-invite-'));
    for (const staleUser of staleUsers) {
      try {
        run(`${SCRIPT} -e dev -t ${TENANT} delete ${staleUser}`);
        console.log(`  [setup] Cleaned up stale user: ${staleUser}`);
      } catch {
        console.log(`  [setup] Failed to clean up ${staleUser} — continuing`);
      }
    }
  } catch {
    console.log('  [setup] Could not list users for cleanup — continuing');
  }

  for (const user of TEST_USERS) {
    const adminFlag = user.admin ? ' --admin' : '';
    try {
      run(
        `${SCRIPT} -e dev -t ${TENANT} create ${user.username} --password ${user.password}${adminFlag}`,
      );
      console.log(`  [setup] Created user: ${user.username}`);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      // User may already exist from a previous failed run
      if (msg.includes('already exists')) {
        console.log(`  [setup] User ${user.username} already exists, resetting password...`);
        run(
          `${SCRIPT} -e dev -t ${TENANT} reset-password ${user.username} --password ${user.password}`,
        );
      } else {
        throw err;
      }
    }
  }

  console.log('\n[E2E Global Setup] All test users ready.\n');
}
