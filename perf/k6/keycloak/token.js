import http from 'k6/http';
import { check } from 'k6';
import { buildOptions } from '../common/thresholds.js';

export const options = Object.assign({}, buildOptions('keycloak'), {
  vus: 1,
  iterations: 1,
});

const KC = __ENV.KEYCLOAK_BASE_URL || '';
const REALM = __ENV.KEYCLOAK_REALM || 'example';
const CLIENT_ID = __ENV.KEYCLOAK_CLIENT_ID || '';
const CLIENT_SECRET = __ENV.KEYCLOAK_CLIENT_SECRET || '';
const USERNAME = __ENV.KEYCLOAK_USERNAME || '';
const PASSWORD = __ENV.KEYCLOAK_PASSWORD || '';

export default function () {
  if (!KC || !CLIENT_ID || !USERNAME || !PASSWORD) {
    return;
  }
  const url = `${KC}/realms/${REALM}/protocol/openid-connect/token`;
  const payload = {
    grant_type: 'password',
    client_id: CLIENT_ID,
    username: USERNAME,
    password: PASSWORD,
  };
  if (CLIENT_SECRET) payload.client_secret = CLIENT_SECRET;

  const params = { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } };
  const res = http.post(url, payload, params);
  check(res, {
    'token 200': (r) => r.status === 200,
    'has access_token': (r) => r.json('access_token') !== undefined,
  });
}



