/**
 * Test user credentials for E2E tests.
 *
 * CI and local runs use DIFFERENT users to avoid conflicts:
 * - CI: e2e-admin, e2e-member, e2e-mailrt, e2e-mailrcv (permanent, never deleted)
 * - Local: e2e-local-admin, e2e-local-member, e2e-local-mailrt, e2e-local-mailrcv (transient, created/deleted per run)
 *
 * Passwords are the same for both — only the username prefix differs.
 */

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const prefix = process.env.CI ? 'e2e' : 'e2e-local';

export const TEST_USERS = {
  admin: {
    username: `${prefix}-admin`,
    password: 'e2e-testpass-admin',
    email: `${prefix}-admin@${baseDomain}`,
  },
  member: {
    username: `${prefix}-member`,
    password: 'e2e-testpass-member',
    email: `${prefix}-member@${baseDomain}`,
  },
  emailTest: {
    username: `${prefix}-mailrt`,
    password: 'e2e-testpass-mailrt',
    email: `${prefix}-mailrt@${baseDomain}`,
  },
  /** Receiver for email round-trip test — member of the echo group. */
  emailRecv: {
    username: `${prefix}-mailrcv`,
    password: 'e2e-testpass-mailrcv',
    email: `${prefix}-mailrcv@${baseDomain}`,
  },
} as const;

export type TestUserRole = keyof typeof TEST_USERS;
