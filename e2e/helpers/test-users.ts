/**
 * Test user credentials for E2E tests.
 * These users are created/deleted by global-setup/teardown via dev-test-users.sh.
 */

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';

export const TEST_USERS = {
  admin: {
    username: 'e2e-admin',
    password: 'e2e-testpass-admin',
    email: `e2e-admin@${baseDomain}`,
  },
  member: {
    username: 'e2e-member',
    password: 'e2e-testpass-member',
    email: `e2e-member@${baseDomain}`,
  },
  emailTest: {
    username: 'e2e-mailrt',
    password: 'e2e-testpass-mailrt',
    email: `e2e-mailrt@${baseDomain}`,
  },
  /** Receiver for email round-trip test — member of the echo group. */
  emailRecv: {
    username: 'e2e-mailrcv',
    password: 'e2e-testpass-mailrcv',
    email: `e2e-mailrcv@${baseDomain}`,
  },
} as const;

export type TestUserRole = keyof typeof TEST_USERS;
