/**
 * Test user credentials for E2E tests.
 *
 * CI and local runs use DIFFERENT users to avoid conflicts:
 * - CI: e2e-<pipeline>-admin, e2e-<pipeline>-member (pipeline-scoped, created/deleted per build)
 * - Local: e2e-local-admin, e2e-local-member (transient, created/deleted per run)
 *
 * Email users (emailTest, emailRecv) are FIXED across pipelines because:
 * - Echo group membership requires known, pre-existing addresses
 * - IMAP master-user auth requires pre-existing Stalwart mail principals
 * - The pool lease system ensures single-tenancy, so fixed users are safe
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
  /** Sender for email round-trip + calendar tests. Fixed (not pipeline-scoped). */
  emailTest: {
    username: 'e2e-mailrt',
    password: 'e2e-testpass-mailrt',
    email: `e2e-mailrt@${baseDomain}`,
  },
  /** Receiver for email round-trip test — member of the echo group. Fixed (not pipeline-scoped). */
  emailRecv: {
    username: 'e2e-mailrcv',
    password: 'e2e-testpass-mailrcv',
    email: `e2e-mailrcv@${baseDomain}`,
  },
} as const;

export type TestUserRole = keyof typeof TEST_USERS;
