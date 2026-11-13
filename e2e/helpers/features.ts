/**
 * Features the target tenant has explicitly switched OFF.
 *
 * `scripts/devbox e2e` sets E2E_DISABLED_FEATURES from the devbox tenant
 * config (e.g. "office,llm" on the full profile), so specs for apps a
 * profile does not deploy skip instead of failing. When the variable is unset
 * (CI, real environments) nothing is disabled and every spec keeps its
 * current behaviour, including the fail-fast prerequisite checks.
 *
 * Names: calendar, office, llm, magic_link, matrix, docs, files, mail,
 * webmail, jitsi, and external_mail (mail really leaving for the internet).
 */
const disabled = new Set(
  (process.env.E2E_DISABLED_FEATURES || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
);

export function featureDisabled(name: string): boolean {
  return disabled.has(name);
}

/** Skip reason shared by the specs. */
export function disabledReason(name: string): string {
  return `${name} is switched off on this tenant (E2E_DISABLED_FEATURES)`;
}
