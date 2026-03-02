/**
 * URL builder for Mothertree services.
 * All URLs derived from E2E_BASE_DOMAIN env var (default: dev.example.com).
 */

const baseDomain = process.env.E2E_BASE_DOMAIN || 'dev.example.com';

export const urls = {
  accountPortal: `https://account.${baseDomain}`,
  adminPortal: `https://admin.${baseDomain}`,
  // Element runs on the matrix subdomain, not a separate element subdomain
  element: `https://matrix.${baseDomain}`,
  docs: `https://docs.${baseDomain}`,
  files: `https://files.${baseDomain}`,
  calendar: `https://calendar.${baseDomain}`,
  jitsi: `https://jitsi.${baseDomain}`,
  office: `https://office.${baseDomain}`,
  webmail: `https://webmail.${baseDomain}`,
  keycloak: `https://auth.${baseDomain}`,
  baseDomain,
};
