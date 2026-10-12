/**
 * Tests for api/guest-redirect.js — recovering a guest's /guest-complete target
 * from the Keycloak page URL /switch-to-magic-link receives as `next`.
 */

const { guestCompleteRedirectFrom } = require('../../api/guest-redirect');

const BASE_URL = 'https://account.test.example.com';

// The URL shape Keycloak 26 puts the passkey page on during a guest's setup.
function keycloakPageUrl(clientData) {
  const params = new URLSearchParams({
    execution: 'VERIFY_EMAIL',
    client_id: 'account-portal',
    tab_id: 'abc123',
  });
  if (clientData !== undefined) params.set('client_data', clientData);
  return `https://auth.test.example.com/realms/test/login-actions/required-action?${params}`;
}

function encodeClientData(obj) {
  return Buffer.from(JSON.stringify(obj)).toString('base64url');
}

describe('guestCompleteRedirectFrom', () => {
  it('returns the guest-complete share URL carried in client_data', () => {
    const next = keycloakPageUrl(encodeClientData({
      ru: `${BASE_URL}/guest-complete?share=AbC123xyz`,
      rt: 'code',
    }));
    expect(guestCompleteRedirectFrom(next, BASE_URL))
      .toBe(`${BASE_URL}/guest-complete?share=AbC123xyz`);
  });

  it('returns the guest-complete doc URL carried in client_data', () => {
    const next = keycloakPageUrl(encodeClientData({ ru: `${BASE_URL}/guest-complete?doc=my-doc`, rt: 'code' }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBe(`${BASE_URL}/guest-complete?doc=my-doc`);
  });

  it('rebuilds the URL from share only, dropping other parameters', () => {
    const next = keycloakPageUrl(encodeClientData({
      ru: `${BASE_URL}/guest-complete?share=s1&next=https://evil.example.org`,
    }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBe(`${BASE_URL}/guest-complete?share=s1`);
  });

  it('returns null for a member setup flow (/complete-registration)', () => {
    const next = keycloakPageUrl(encodeClientData({ ru: `${BASE_URL}/complete-registration`, rt: 'code' }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it('returns null when the redirect points at another host', () => {
    const next = keycloakPageUrl(encodeClientData({ ru: 'https://evil.example.org/guest-complete?share=s1' }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it('returns null for a look-alike host sharing the base as a prefix', () => {
    const next = keycloakPageUrl(encodeClientData({
      ru: 'https://account.test.example.com.evil.example.org/guest-complete?share=s1',
    }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it('returns null for plain http on the right host', () => {
    const next = keycloakPageUrl(encodeClientData({ ru: 'http://account.test.example.com/guest-complete?share=s1' }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it('returns null when guest-complete carries neither share nor doc', () => {
    const next = keycloakPageUrl(encodeClientData({ ru: `${BASE_URL}/guest-complete` }));
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it('returns null without client_data (e.g. the action-token URL)', () => {
    const next = 'https://auth.test.example.com/realms/test/login-actions/action-token?key=abc';
    expect(guestCompleteRedirectFrom(next, BASE_URL)).toBeNull();
  });

  it.each([
    ['not base64 JSON', 'not-json-at-all'],
    ['JSON without ru', encodeClientData({ rt: 'code' })],
    ['non-string ru', encodeClientData({ ru: 42 })],
    ['unparseable ru', encodeClientData({ ru: 'not a url' })],
  ])('returns null for %s', (_label, clientData) => {
    expect(guestCompleteRedirectFrom(keycloakPageUrl(clientData), BASE_URL)).toBeNull();
  });

  it('returns null when next is not a URL', () => {
    expect(guestCompleteRedirectFrom('not-a-url', BASE_URL)).toBeNull();
  });
});
