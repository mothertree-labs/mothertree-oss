import http from 'k6/http';
import { fail } from 'k6';

// Simple per-VU token cache
const tokenCache = {};

function formEncode(data) {
  return Object.keys(data)
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(data[k])}`)
    .join('&');
}

export function getKeycloakToken(username, password) {
  const base = __ENV.KEYCLOAK_BASE_URL || '';
  const realm = __ENV.KEYCLOAK_REALM || '';
  const clientId = __ENV.KEYCLOAK_CLIENT_ID || '';
  const clientSecret = __ENV.KEYCLOAK_CLIENT_SECRET || '';

  if (!base || !realm || !clientId) {
    fail('Missing KEYCLOAK_BASE_URL or KEYCLOAK_REALM or KEYCLOAK_CLIENT_ID');
  }

  const cacheKey = `${__VU}:${username}`;
  const now = Date.now() / 1000;
  const cached = tokenCache[cacheKey];
  if (cached && cached.expiresAt > now + 5) {
    return cached.token;
  }

  const url = `${base}/realms/${realm}/protocol/openid-connect/token`;
  const payload = {
    grant_type: 'password',
    client_id: clientId,
    username,
    password,
  };
  if (clientSecret) payload.client_secret = clientSecret;

  const res = http.post(
    url,
    formEncode(payload),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  );
  if (res.status !== 200) {
    return '';
  }
  const accessToken = res.json('access_token') || '';
  const expiresIn = Number(res.json('expires_in') || 60);
  tokenCache[cacheKey] = {
    token: accessToken,
    expiresAt: now + expiresIn * 0.9, // refresh a bit early
  };
  return accessToken;
}


