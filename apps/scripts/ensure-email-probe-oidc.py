#!/usr/bin/env python3
"""Ensure the email probe can log in to Stalwart the way Roundcube does.

Keycloak side of the probe's synthetic OIDC login (#715 follow-up):

  * a confidential client (default `email-probe-login`) that may only use the
    password grant (no browser flow, no service account, no full scope), with
    the `stalwart-audience` mapper so its tokens carry aud=stalwart;
  * the probe's Keycloak user (`email-probe`, created by
    scripts/create-email-probe-user) can get a token with the given password.

Then it checks a real token: aud contains `stalwart` and preferred_username is
the probe user. On a failed login it clears any brute-force lockout and resets
the user's password to the given value, once, then checks again.

Everything comes from the environment, never argv (a shared CI host can read
argv through ps). Nothing secret is printed.

Env: KC_URL (Keycloak base, e.g. http://localhost:PORT), KC_ADMIN_PASSWORD,
     KC_REALM, PROBE_CLIENT_ID, PROBE_CLIENT_SECRET, PROBE_USERNAME,
     PROBE_PASSWORD
Exit 0 when the probe can log in, 1 otherwise.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KC_URL = os.environ["KC_URL"].rstrip("/")
REALM = os.environ["KC_REALM"]
CLIENT_ID = os.environ["PROBE_CLIENT_ID"]
CLIENT_SECRET = os.environ["PROBE_CLIENT_SECRET"]
USERNAME = os.environ["PROBE_USERNAME"]
PASSWORD = os.environ["PROBE_PASSWORD"]
AUDIENCE = "stalwart"


def say(msg):
    print(msg, flush=True)


def request(method, path, token=None, body=None, form=None):
    """Return (status, parsed JSON or None). Never raises on HTTP errors."""
    headers = {}
    data = None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(KC_URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        status = e.code
    try:
        return status, (json.loads(raw) if raw else None)
    except ValueError:
        return status, None


def admin_token():
    status, data = request("POST", "/realms/master/protocol/openid-connect/token", form={
        "grant_type": "password", "client_id": "admin-cli",
        "username": "admin", "password": os.environ["KC_ADMIN_PASSWORD"],
    })
    if status != 200 or not data or not data.get("access_token"):
        sys.exit(f"Keycloak admin login failed (HTTP {status})")
    return data["access_token"]


def ensure_client(tok):
    rep = {
        "clientId": CLIENT_ID,
        "name": "Email probe (synthetic mail login)",
        "description": "Password grant for the email-probe bot only; tokens carry aud=stalwart.",
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": False,
        "clientAuthenticatorType": "client-secret",
        "secret": CLIENT_SECRET,
        "standardFlowEnabled": False,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": True,
        "serviceAccountsEnabled": False,
        "frontchannelLogout": False,
        "redirectUris": [],
        "webOrigins": [],
        "fullScopeAllowed": False,
    }
    base = f"/admin/realms/{REALM}/clients"
    status, found = request("GET", f"{base}?clientId={urllib.parse.quote(CLIENT_ID)}", tok)
    if status != 200:
        sys.exit(f"Could not look up client {CLIENT_ID} (HTTP {status})")
    if found:
        cid = found[0]["id"]
        status, _ = request("PUT", f"{base}/{cid}", tok, body=rep)
        if status != 204:
            sys.exit(f"Could not update client {CLIENT_ID} (HTTP {status})")
        say(f"Client {CLIENT_ID}: updated")
    else:
        status, _ = request("POST", base, tok, body=rep)
        if status != 201:
            sys.exit(f"Could not create client {CLIENT_ID} (HTTP {status})")
        status, found = request("GET", f"{base}?clientId={urllib.parse.quote(CLIENT_ID)}", tok)
        if status != 200 or not found:
            sys.exit(f"Client {CLIENT_ID} not found after creating it (HTTP {status})")
        cid = found[0]["id"]
        say(f"Client {CLIENT_ID}: created")

    status, mappers = request("GET", f"{base}/{cid}/protocol-mappers/models", tok)
    if status != 200:
        sys.exit(f"Could not list mappers of {CLIENT_ID} (HTTP {status})")
    if not any(m.get("name") == "stalwart-audience" for m in mappers or []):
        status, _ = request("POST", f"{base}/{cid}/protocol-mappers/models", tok, body={
            "name": "stalwart-audience",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-audience-mapper",
            "config": {
                "included.client.audience": AUDIENCE,
                "id.token.claim": "false",
                "access.token.claim": "true",
            },
        })
        if status != 201:
            sys.exit(f"Could not add the stalwart-audience mapper (HTTP {status})")
        say("Mapper stalwart-audience: added")


def find_user(tok):
    status, users = request(
        "GET", f"/admin/realms/{REALM}/users?username={urllib.parse.quote(USERNAME)}&exact=true", tok)
    if status != 200:
        sys.exit(f"Could not look up user {USERNAME} (HTTP {status})")
    if not users:
        sys.exit(f"Keycloak user {USERNAME} does not exist (scripts/create-email-probe-user creates it)")
    return users[0]["id"]


def probe_login():
    """Return (ok, reason). Checks the token's audience and username too."""
    status, data = request("POST", f"/realms/{REALM}/protocol/openid-connect/token", form={
        "grant_type": "password", "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
        "username": USERNAME, "password": PASSWORD, "scope": "openid",
    })
    if status != 200 or not data or not data.get("access_token"):
        err = (data or {}).get("error", "?")
        desc = (data or {}).get("error_description", "")
        return False, f"HTTP {status} {err} {desc}".strip()
    payload = data["access_token"].split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if AUDIENCE not in auds:
        return False, f"token audience {auds} lacks {AUDIENCE}"
    if claims.get("preferred_username") != USERNAME:
        return False, "token preferred_username is not the probe user"
    return True, f"iss={claims.get('iss')}"


def main():
    tok = admin_token()
    ensure_client(tok)
    uid = find_user(tok)

    ok, reason = probe_login()
    if not ok:
        say(f"Probe login failed ({reason}); resetting the probe user's password")
        # A lockout from earlier failures would make the reset look useless.
        request("DELETE", f"/admin/realms/{REALM}/attack-detection/brute-force/users/{uid}", tok)
        status, _ = request("PUT", f"/admin/realms/{REALM}/users/{uid}/reset-password", tok,
                            body={"type": "password", "value": PASSWORD, "temporary": False})
        if status != 204:
            sys.exit(f"Could not set the probe user's password (HTTP {status})")
        ok, reason = probe_login()
    if not ok:
        sys.exit(f"Probe login still fails: {reason}")
    say(f"Probe login OK: aud includes {AUDIENCE}, user {USERNAME}, {reason}")


if __name__ == "__main__":
    main()
