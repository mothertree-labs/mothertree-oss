import { execSync } from 'child_process';
import * as path from 'path';

const REPO_ROOT = path.resolve(__dirname, '..');
const SCRIPT = path.join(REPO_ROOT, 'scripts', 'dev-test-users.sh');
const TENANT = process.env.E2E_TENANT || 'example';
const IS_CI = !!process.env.CI || !!process.env.BUILDKITE;

const TEST_USERNAMES = ['e2e-admin', 'e2e-member', 'e2e-email-test1'];

function run(cmd: string): void {
  console.log(`  [teardown] ${cmd}`);
  try {
    execSync(cmd, {
      cwd: REPO_ROOT,
      encoding: 'utf-8',
      timeout: 60_000,
      env: { ...process.env, PATH: process.env.PATH },
    });
  } catch {
    // Best-effort cleanup — don't fail teardown if a user is already gone
  }
}

export default async function globalTeardown(): Promise<void> {
  // In CI, test users are permanent — never delete them.
  if (IS_CI) {
    console.log('\n[E2E Global Teardown] CI detected — skipping (users are permanent).\n');
    return;
  }

  // Skip teardown if E2E_KEEP_USERS is set (useful for debugging)
  if (process.env.E2E_KEEP_USERS) {
    console.log('\n[E2E Global Teardown] E2E_KEEP_USERS set — skipping user cleanup.\n');
    return;
  }

  console.log('\n[E2E Global Teardown] Deleting test users...\n');

  for (const username of TEST_USERNAMES) {
    run(`${SCRIPT} -e dev -t ${TENANT} delete ${username}`);
    console.log(`  [teardown] Deleted user: ${username}`);
  }

  console.log('\n[E2E Global Teardown] Cleanup complete.\n');
}
