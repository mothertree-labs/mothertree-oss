#!/usr/bin/env python3
"""Ensure the email probe can log in to Stalwart the way Roundcube does.

Keycloak side of the probe's synthetic OIDC login (#715 follow-up):

  * a confidential client (default `email-probe-login`) that may only use the
    password grant (no browser flow, no service account, no full scope), with
    the `stalwart-audience` mapper so its tokens carry aud=stalwart;
  * the probe's Keycloak user (`email-probe`, created by
    scripts/create-email-probe-user) can get a token with the given password.

The password grant is gated to the probe: the client's direct-grant flow is
overridden with `email-probe direct grant`, which denies any user without the
client role `probe` (held only by the probe user) BEFORE the password is
checked. A leaked client secret therefore cannot be used to log in as anyone
else, nor as an oracle for other users' passwords.

Then it checks a real token: aud contains `stalwart` and preferred_username is
the probe user, and logs that session out again. On a failed login it clears
any brute-force lockout and resets the probe user's password to the given
value (after checking the user's email), once, then checks again.

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
PROBE_EMAIL = os.environ["PROBE_EMAIL"]
AUDIENCE = "stalwart"
ROLE = "probe"
FLOW = "email-probe direct grant"
SUBFLOW = "email-probe deny other users"
# (level, provider or subflow alias, requirement), in order.
FLOW_SHAPE = [
    (0, "direct-grant-validate-username", "REQUIRED"),
    (0, SUBFLOW, "CONDITIONAL"),
    (1, "conditional-user-role", "REQUIRED"),
    (1, "deny-access-authenticator", "REQUIRED"),
    (0, "direct-grant-validate-password", "REQUIRED"),
]


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


def _flow_shape(tok):
    status, ex = request("GET", f"/admin/realms/{REALM}/authentication/flows/"
                         f"{urllib.parse.quote(FLOW)}/executions", tok)
    if status != 200:
        return None, None
    shape = [(e.get("level"), e.get("providerId") or e.get("displayName"), e.get("requirement"))
             for e in ex]
    return shape, ex


def _flow_id(tok):
    status, flows = request("GET", f"/admin/realms/{REALM}/authentication/flows", tok)
    if status != 200:
        sys.exit(f"Could not list authentication flows (HTTP {status})")
    for f in flows:
        if f.get("alias") == FLOW:
            return f["id"]
    return None


def _role_config_ok(tok, ex):
    cond = next((e for e in ex if e.get("providerId") == "conditional-user-role"), None)
    if not cond or not cond.get("authenticationConfig"):
        return False
    status, cfg = request("GET", f"/admin/realms/{REALM}/authentication/config/"
                          f"{cond['authenticationConfig']}", tok)
    c = (cfg or {}).get("config", {}) if status == 200 else {}
    return c.get("condUserRole") == f"{CLIENT_ID}.{ROLE}" and c.get("negate") == "true"


def set_client(tok, client_uuid, **fields):
    """GET-modify-PUT the client; exits on failure."""
    path = f"/admin/realms/{REALM}/clients/{client_uuid}"
    status, client = request("GET", path, tok)
    if status != 200:
        sys.exit(f"Could not read client {CLIENT_ID} (HTTP {status})")
    client.update(fields)
    status, _ = request("PUT", path, tok, body=client)
    if status != 204:
        sys.exit(f"Could not update client {CLIENT_ID} (HTTP {status})")
    return client


def ensure_flow(tok, client_uuid):
    """The client's own direct-grant flow; returns (id, built_now)."""
    flows = f"/admin/realms/{REALM}/authentication/flows"
    shape, ex = _flow_shape(tok)
    if shape == FLOW_SHAPE and _role_config_ok(tok, ex):
        return _flow_id(tok), False
    fid = _flow_id(tok)
    if fid:
        # Wrong shape: rebuild from scratch. Fail closed: the password grant
        # is switched off BEFORE the flow is unbound, and only switched back
        # on (main) once the rebuilt flow is bound and verified. Otherwise a
        # failure halfway would leave the client on the realm's default
        # direct-grant flow, which admits every user.
        say(f"Flow '{FLOW}' does not have the expected shape; rebuilding it")
        # An empty value removes a binding; an empty map changes nothing.
        set_client(tok, client_uuid, directAccessGrantsEnabled=False,
                   authenticationFlowBindingOverrides={"direct_grant": ""})
        status, _ = request("DELETE", f"{flows}/{fid}", tok)
        if status != 204:
            sys.exit(f"Could not delete the old flow '{FLOW}' (HTTP {status})")
    q = urllib.parse.quote
    steps = [
        ("POST", flows, {"alias": FLOW, "providerId": "basic-flow", "topLevel": True, "builtIn": False,
                         "description": "Password grant for the email probe only (see ensure-email-probe-oidc.py)"}),
        ("POST", f"{flows}/{q(FLOW)}/executions/execution", {"provider": "direct-grant-validate-username"}),
        ("POST", f"{flows}/{q(FLOW)}/executions/flow",
         {"alias": SUBFLOW, "type": "basic-flow", "provider": "registration-page-form", "description": ""}),
        ("POST", f"{flows}/{q(SUBFLOW)}/executions/execution", {"provider": "conditional-user-role"}),
        ("POST", f"{flows}/{q(SUBFLOW)}/executions/execution", {"provider": "deny-access-authenticator"}),
        ("POST", f"{flows}/{q(FLOW)}/executions/execution", {"provider": "direct-grant-validate-password"}),
    ]
    for method, path, body in steps:
        status, _ = request(method, path, tok, body=body)
        if status not in (201, 204):
            sys.exit(f"Could not build flow '{FLOW}': {method} {path.split('/')[-1]} -> HTTP {status}")
    shape, ex = _flow_shape(tok)
    if shape is None:
        sys.exit(f"Flow '{FLOW}' not readable after creating it")
    for e, (_, _, want) in zip(ex, FLOW_SHAPE):
        if e.get("requirement") != want:
            e["requirement"] = want
            status, _ = request("PUT", f"{flows}/{q(FLOW)}/executions", tok, body=e)
            if status not in (202, 204):
                sys.exit(f"Could not set requirement {want} in flow '{FLOW}' (HTTP {status})")
    cond = next(e for e in ex if e.get("providerId") == "conditional-user-role")
    status, _ = request("POST", f"/admin/realms/{REALM}/authentication/executions/{cond['id']}/config", tok,
                        body={"alias": "email-probe-role-missing",
                              "config": {"condUserRole": f"{CLIENT_ID}.{ROLE}", "negate": "true"}})
    if status != 201:
        sys.exit(f"Could not configure the role condition (HTTP {status})")
    shape, ex = _flow_shape(tok)
    if shape != FLOW_SHAPE or not _role_config_ok(tok, ex):
        sys.exit(f"Flow '{FLOW}' has an unexpected shape after building it: {shape}")
    say(f"Flow '{FLOW}': built")
    return _flow_id(tok), True


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
        # directAccessGrantsEnabled is left out on update (unchanged) and false
        # on create: main() turns it on only once the gated flow is bound.
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
        status, _ = request("POST", base, tok, body=dict(rep, directAccessGrantsEnabled=False))
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

    # Client role held only by the probe user; the flow denies everyone else.
    status, _ = request("GET", f"{base}/{cid}/roles/{ROLE}", tok)
    if status == 404:
        status, _ = request("POST", f"{base}/{cid}/roles", tok,
                            body={"name": ROLE, "description": "May use the email-probe password grant"})
        if status != 201:
            sys.exit(f"Could not create client role {ROLE} (HTTP {status})")
    elif status != 200:
        sys.exit(f"Could not read client role {ROLE} (HTTP {status})")

    flow_id, built = ensure_flow(tok, cid)
    status, client = request("GET", f"{base}/{cid}", tok)
    if status != 200:
        sys.exit(f"Could not read client {CLIENT_ID} (HTTP {status})")
    if (client.get("authenticationFlowBindingOverrides") or {}).get("direct_grant") != flow_id:
        # Never bind/rebind with the grant on: an unbound moment uses the
        # realm's default flow.
        set_client(tok, cid, directAccessGrantsEnabled=False,
                   authenticationFlowBindingOverrides={"direct_grant": flow_id})
        say(f"Client {CLIENT_ID}: direct grant bound to '{FLOW}'")
        built = True
    return cid, built


def find_user(tok):
    status, users = request(
        "GET", f"/admin/realms/{REALM}/users?username={urllib.parse.quote(USERNAME)}&exact=true", tok)
    if status != 200:
        sys.exit(f"Could not look up user {USERNAME} (HTTP {status})")
    if not users:
        sys.exit(f"Keycloak user {USERNAME} does not exist (scripts/create-email-probe-user creates it)")
    # Never touch (role, password) an account that merely shares the name.
    if (users[0].get("email") or "").lower() != PROBE_EMAIL.lower():
        sys.exit(f"Keycloak user {USERNAME} does not have the probe's email; refusing to manage it")
    return users[0]["id"]


def ensure_user_role(tok, uid, cid):
    path = f"/admin/realms/{REALM}/users/{uid}/role-mappings/clients/{cid}"
    status, mapped = request("GET", path, tok)
    if status != 200:
        sys.exit(f"Could not read the probe user's client roles (HTTP {status})")
    if any(r.get("name") == ROLE for r in mapped or []):
        return
    status, role = request("GET", f"/admin/realms/{REALM}/clients/{cid}/roles/{ROLE}", tok)
    if status != 200:
        sys.exit(f"Could not read client role {ROLE} (HTTP {status})")
    status, _ = request("POST", path, tok, body=[role])
    if status != 204:
        sys.exit(f"Could not give the probe user role {ROLE} (HTTP {status})")
    say(f"User {USERNAME}: given client role {ROLE}")


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
    # Do not leave a (30-day) Keycloak session behind, whatever the checks say.
    if data.get("refresh_token"):
        request("POST", f"/realms/{REALM}/protocol/openid-connect/logout", form={
            "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
            "refresh_token": data["refresh_token"]})
    payload = data["access_token"].split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    aud = claims.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if AUDIENCE not in auds:
        return False, f"token audience {auds} lacks {AUDIENCE}"
    if claims.get("preferred_username") != USERNAME:
        return False, "token preferred_username is not the probe user"
    return True, f"iss={claims.get('iss')}"


def gate_check(tok, uid, cid):
    """Prove on the running Keycloak that the flow denies a user without the
    role: take the probe's role away, expect its login to fail, give it back.
    Run whenever the flow or its binding was just (re)made, or the grant was
    off. If the login still works, the grant is switched off again."""
    role_path = f"/admin/realms/{REALM}/users/{uid}/role-mappings/clients/{cid}"
    status, role = request("GET", f"/admin/realms/{REALM}/clients/{cid}/roles/{ROLE}", tok)
    if status != 200:
        sys.exit(f"Could not read client role {ROLE} (HTTP {status})")
    status, _ = request("DELETE", role_path, tok, body=[role])
    if status != 204:
        set_client(tok, cid, directAccessGrantsEnabled=False)
        sys.exit(f"Gate check: could not remove role {ROLE} (HTTP {status}); password grant left off")
    ok, _ = probe_login()
    ensure_user_role(tok, uid, cid)
    if ok:
        set_client(tok, cid, directAccessGrantsEnabled=False)
        sys.exit(f"Gate check FAILED: a user without role {ROLE} got a token; password grant switched off")
    say(f"Gate check: a user without role {ROLE} is refused")


def main():
    tok = admin_token()
    cid, verify_gate = ensure_client(tok)
    uid = find_user(tok)
    ensure_user_role(tok, uid, cid)

    status, client = request("GET", f"/admin/realms/{REALM}/clients/{cid}", tok)
    if status != 200:
        sys.exit(f"Could not read client {CLIENT_ID} (HTTP {status})")
    if not client.get("directAccessGrantsEnabled"):
        # The gated flow is bound and its shape verified: safe to switch on.
        set_client(tok, cid, directAccessGrantsEnabled=True)
        say(f"Client {CLIENT_ID}: password grant on (gated by '{FLOW}')")
        verify_gate = True

    ok, reason = probe_login()
    if not ok:
        say(f"Probe login failed ({reason}); resetting the probe user's password")
        # A lockout from earlier failures would make the reset look useless.
        status, bf = request("GET", f"/admin/realms/{REALM}/attack-detection/brute-force/users/{uid}", tok)
        if status == 200 and bf and (bf.get("disabled") or bf.get("numFailures")):
            say(f"Probe user had a brute-force record (failures={bf.get('numFailures')}, "
                f"locked={bf.get('disabled')}); clearing it")
        request("DELETE", f"/admin/realms/{REALM}/attack-detection/brute-force/users/{uid}", tok)
        status, _ = request("PUT", f"/admin/realms/{REALM}/users/{uid}/reset-password", tok,
                            body={"type": "password", "value": PASSWORD, "temporary": False})
        if status != 204:
            sys.exit(f"Could not set the probe user's password (HTTP {status})")
        ok, reason = probe_login()
    if not ok:
        sys.exit(f"Probe login still fails: {reason}")
    say(f"Probe login OK: aud includes {AUDIENCE}, user {USERNAME}, {reason}")
    # Only now (the probe's own login works) does a refused login without
    # the role prove the gate rather than a bad password.
    if verify_gate:
        gate_check(tok, uid, cid)


if __name__ == "__main__":
    main()
