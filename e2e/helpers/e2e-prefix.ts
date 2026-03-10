/**
 * Pipeline-scoped prefix for ephemeral E2E test users.
 *
 * In CI, each pipeline gets a unique prefix based on CI_PIPELINE_NUMBER,
 * preventing cross-pipeline interference when runs overlap. The cleanup
 * step (ci/scripts/e2e-cleanup.sh) deletes all users matching its
 * pipeline's prefix after shards complete.
 *
 * Local runs use a timestamp-based prefix since global-setup handles cleanup.
 */
const pipelineNum = process.env.CI_PIPELINE_NUMBER;
const runId = pipelineNum || `l${Date.now()}`;

/**
 * Generate a pipeline-scoped user identifier.
 *
 * @param type - The test category (e.g. 'guest', 'bridge', 'invite')
 * @returns Prefixed identifier like "e2e-p356-guest" (CI) or "e2e-l1773103162891-guest" (local)
 *
 * Usage: `${e2ePrefix('guest')}-${Date.now()}@external-test.example`
 */
export function e2ePrefix(type: string): string {
  return `e2e-${runId}-${type}`;
}
