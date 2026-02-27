import { execSync } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

const REPO_ROOT = path.resolve(__dirname, '..');
const SCRIPT = path.join(REPO_ROOT, 'scripts', 'dev-test-users.sh');
const TENANT = process.env.E2E_TENANT || 'example';
const IS_CI = !!process.env.CI;

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

  // Only delete users that global-setup created fresh this run.
  // Pre-existing users (e.g. permanent CI users) are left alone.
  const markerPath = path.join(__dirname, '.auth', 'created-users.json');
  let usersToDelete: string[] = [];
  try {
    usersToDelete = JSON.parse(fs.readFileSync(markerPath, 'utf-8'));
  } catch {
    console.log('\n[E2E Global Teardown] No created-users marker — skipping cleanup.\n');
    return;
  }

  if (usersToDelete.length === 0) {
    console.log('\n[E2E Global Teardown] All users were pre-existing — skipping cleanup.\n');
    return;
  }

  console.log('\n[E2E Global Teardown] Deleting test users created by this run...\n');

  for (const username of usersToDelete) {
    run(`${SCRIPT} -e dev -t ${TENANT} delete ${username}`);
    console.log(`  [teardown] Deleted user: ${username}`);
  }

  console.log('\n[E2E Global Teardown] Cleanup complete.\n');
}
