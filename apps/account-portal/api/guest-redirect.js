/**
 * The redirect a guest's setup flow was started with, recovered from `next` (the
 * Keycloak required-action URL the passkey page was on). Keycloak carries the
 * client's redirect_uri there as client_data = base64url({"ru": ...}).
 *
 * Only our own <baseUrl>/guest-complete?share=|doc= is accepted, rebuilt from
 * its parts; anything else (members' /complete-registration, other hosts,
 * unparseable input) returns null.
 */
function guestCompleteRedirectFrom(next, baseUrl) {
  try {
    const clientData = new URL(next).searchParams.get('client_data');
    if (!clientData) return null;
    const ru = JSON.parse(Buffer.from(clientData, 'base64url').toString('utf8')).ru;
    if (typeof ru !== 'string') return null;
    const target = new URL(ru);
    const base = new URL(baseUrl);
    if (target.origin !== base.origin || target.pathname !== '/guest-complete') return null;
    const share = target.searchParams.get('share');
    const doc = target.searchParams.get('doc');
    if (share) return `${base.origin}/guest-complete?share=${encodeURIComponent(share)}`;
    if (doc) return `${base.origin}/guest-complete?doc=${encodeURIComponent(doc)}`;
  } catch {
    // Not a Keycloak URL we understand
  }
  return null;
}

module.exports = { guestCompleteRedirectFrom };
