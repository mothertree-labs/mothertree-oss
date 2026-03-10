/**
 * Test user credentials for E2E tests.
 *
 * CI and local runs use DIFFERENT users to avoid conflicts:
 * - CI: e2e-<pipeline>-admin, e2e-<pipeline>-member, etc. (pipeline-scoped, created/deleted per build)
 * - Local: e2e-local-admin, e2e-local-member, etc. (transient, created/deleted per run)
 *
 * The CI pipeline number is included in the prefix to isolate parallel builds.
 * Passwords are the same for both — only the username prefix differs.
 */

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';
const pipelineNum = process.env.CI_PIPELINE_NUMBER || '';
const prefix = process.env.CI
  ? (pipelineNum ? `e2e-${pipelineNum}` : 'e2e')
  : 'e2e-local';

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
