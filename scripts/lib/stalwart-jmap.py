#!/usr/bin/env python3
"""Stalwart v1 JMAP management client for the shell scripts (issue #715).

Stalwart v1 replaced the 0.15 REST API (/api/principal, /api/reload, ...) with
JMAP management methods under the `urn:stalwart:jmap` capability. Every call is
a POST to <STALWART_URL>/jmap/ with HTTP Basic auth as the recovery admin.
Errors come back as HTTP 200: a method-level ["error", {type}] response, or
per-id notCreated / notUpdated / notDestroyed entries.

This mirrors apps/admin-portal/api/stalwart.js (the reference client). Only
the Python standard library is used, so it runs anywhere python3 does.

Environment:
  STALWART_URL             base URL, e.g. http://localhost:18090 (no trailing /jmap)
  STALWART_ADMIN_PASSWORD  recovery admin password (username is "admin")
  STALWART_TIMEOUT         per-request timeout in seconds (default 30)

Commands (secrets are only ever written to stdout by reset-app-password):
  ping                          authenticated GET /jmap/session; exit 0 on 200,
                                3 when the admin credentials are rejected
  domains                       print configured domain names, one per line
  accounts [--prefix P]         print "<email>\\t<name>\\t<id>" per user account
                                (the bootstrap/recovery admin is skipped)
  account-exists EMAIL          exit 0 when the account exists, 4 when not
  ensure-account EMAIL [--description D] [--alias LOCAL ...]
                                create the account if missing; print
                                "created" or "exists"
  delete-accounts               read emails (one per line) on stdin and destroy
                                those accounts; print "deleted|missing|failed
                                <email>" per line; exit 1 if any failed
  reset-app-password EMAIL NAME revoke every app password described NAME, create
                                one, print its server-generated secret
  reload                        ReloadSettings (clears directory/RCPT caches)
  lists                         print mailing lists as JSON
  list-get ADDRESS              print one mailing list as JSON; exit 4 if absent
  list-create LOCAL DESCRIPTION [RECIPIENT ...]
                                print "created" or "exists"
  list-members ADDRESS (--add|--remove) RECIPIENT ...
  list-delete ADDRESS           exit 4 if absent

Exit codes: 0 ok, 1 error, 2 usage, 3 admin auth rejected, 4 not found.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

USING = ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"]
PAGE_SIZE = 500  # Stalwart v1 maxObjectsInGet / maxObjectsInSet


class JmapError(Exception):
    pass


class AuthRejected(JmapError):
    pass


def _config():
    url = os.environ.get("STALWART_URL", "").rstrip("/")
    password = os.environ.get("STALWART_ADMIN_PASSWORD", "")
    if not url:
        raise JmapError("STALWART_URL is not set")
    if not password:
        raise JmapError("STALWART_ADMIN_PASSWORD is not set")
    timeout = float(os.environ.get("STALWART_TIMEOUT") or 30)
    auth = "Basic " + base64.b64encode(f"admin:{password}".encode()).decode()
    return url, auth, timeout


def _http(method, path, body=None):
    url, auth, timeout = _config()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url + path, data=data, method=method)
    req.add_header("Authorization", auth)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise AuthRejected(f"Stalwart rejected the admin credentials (HTTP {e.code})")
        raise JmapError(f"Stalwart HTTP {e.code} on {path}")
    except (urllib.error.URLError, OSError) as e:
        raise JmapError(f"Stalwart unreachable ({path}): {e}")


def jmap(calls):
    """Send one JMAP request; return {callId: args}. Raises on method errors."""
    _, raw = _http("POST", "/jmap/", {"using": USING, "methodCalls": calls})
    try:
        data = json.loads(raw)
    except ValueError:
        raise JmapError("Stalwart returned a non-JSON JMAP response")
    results = {}
    for name, args, call_id in data.get("methodResponses", []):
        if name == "error":
            method = next((c[0] for c in calls if c[2] == call_id), call_id)
            desc = args.get("description")
            raise JmapError(f"{method} failed: {args.get('type', 'unknown')}" + (f" - {desc}" if desc else ""))
        results[call_id] = args
    for method, _, call_id in calls:
        if call_id not in results:
            raise JmapError(f"{method} failed: no response for call {call_id!r}")
    return results


def describe(err):
    if not err:
        return "unknown"
    out = err.get("type", "unknown")
    if err.get("description"):
        out += " - " + err["description"]
    if err.get("properties"):
        out += " [" + ", ".join(err["properties"]) + "]"
    return out


def assert_set_ok(label, result):
    for key in ("notCreated", "notUpdated", "notDestroyed"):
        failures = result.get(key) or {}
        if failures:
            obj_id, err = next(iter(failures.items()))
            raise JmapError(f"{label} failed ({obj_id}): {describe(err)}")


def split_email(email):
    addr = (email or "").strip().lower()
    local, sep, domain = addr.rpartition("@")
    if not sep or not local or not domain:
        raise JmapError(f"invalid email address: {email!r}")
    return local, domain, addr


_domain_cache = {}


def domain_id(domain):
    if domain not in _domain_cache:
        res = jmap([["x:Domain/query", {"filter": {"name": domain}}, "d"]])
        ids = res["d"].get("ids") or []
        if not ids:
            raise JmapError(f"Stalwart domain {domain!r} is not configured (deploy-stalwart.sh creates it)")
        _domain_cache[domain] = ids[0]
    return _domain_cache[domain]


ACCOUNT_PROPS = ["@type", "name", "emailAddress", "roles", "aliases", "description"]


def find_account(email):
    local, domain, addr = split_email(email)
    did = domain_id(domain)
    res = jmap([
        ["x:Account/query", {"filter": {"name": local, "domainId": did}}, "q"],
        ["x:Account/get", {"#ids": {"resultOf": "q", "name": "x:Account/query", "path": "/ids"},
                           "properties": ACCOUNT_PROPS}, "g"],
    ])
    for acct in res["g"].get("list") or []:
        if (acct.get("emailAddress") or "").lower() == addr:
            return acct
    return None


def is_admin(acct):
    roles = acct.get("roles") or {}
    return acct.get("name") == "admin" or roles.get("@type") == "Admin"


def list_accounts():
    accounts, position = [], 0
    while True:
        res = jmap([
            ["x:Account/query", {"position": position, "limit": PAGE_SIZE, "calculateTotal": True}, "q"],
            ["x:Account/get", {"#ids": {"resultOf": "q", "name": "x:Account/query", "path": "/ids"},
                               "properties": ACCOUNT_PROPS}, "g"],
        ])
        ids = res["q"].get("ids") or []
        accounts.extend(res["g"].get("list") or [])
        position += len(ids)
        total = res["q"].get("total", position)
        if not ids or position >= total:
            return accounts


def user_accounts():
    return [a for a in list_accounts()
            if a.get("@type", "User") == "User" and a.get("emailAddress") and not is_admin(a)]


def cmd_ping(_args):
    status, _ = _http("GET", "/jmap/session")
    print(status)
    return 0 if status == 200 else 1


def cmd_domains(_args):
    res = jmap([
        ["x:Domain/query", {}, "q"],
        ["x:Domain/get", {"#ids": {"resultOf": "q", "name": "x:Domain/query", "path": "/ids"},
                          "properties": ["name"]}, "g"],
    ])
    for d in res["g"].get("list") or []:
        print(d.get("name", ""))
    return 0


def cmd_accounts(args):
    for a in user_accounts():
        if args.prefix and not a.get("name", "").startswith(args.prefix):
            continue
        print(f"{a['emailAddress']}\t{a.get('name', '')}\t{a['id']}")
    return 0


def cmd_account_exists(args):
    return 0 if find_account(args.email) else 4


def cmd_ensure_account(args):
    local, domain, _ = split_email(args.email)
    if find_account(args.email):
        print("exists")
        return 0
    did = domain_id(domain)
    account = {"@type": "User", "name": local, "domainId": did, "description": args.description or local}
    if args.alias:
        account["aliases"] = {str(i): {"name": a.lower(), "domainId": did, "enable": True}
                              for i, a in enumerate(args.alias)}
    res = jmap([["x:Account/set", {"create": {"n": account}}, "c"]])
    failed = (res["c"].get("notCreated") or {}).get("n")
    if failed:
        # Duplicate (a concurrent create, or a retry after a timed-out create
        # that actually landed): same outcome as 0.15's fieldAlreadyExists.
        if failed.get("type") == "primaryKeyViolation":
            print("exists")
            return 0
        raise JmapError(f"account create for {args.email} failed: {describe(failed)}")
    if not (res["c"].get("created") or {}).get("n", {}).get("id"):
        raise JmapError(f"account create for {args.email} returned no id")
    print("created")
    return 0


def cmd_delete_accounts(_args):
    wanted = [line.strip().lower() for line in sys.stdin if line.strip()]
    if not wanted:
        return 0
    by_email = {a["emailAddress"].lower(): a["id"] for a in user_accounts()}
    rc = 0
    for email in wanted:
        acct_id = by_email.get(email)
        if not acct_id:
            print(f"missing {email}")
            continue
        res = jmap([["x:Account/set", {"destroy": [acct_id]}, "x"]])
        err = (res["x"].get("notDestroyed") or {}).get(acct_id)
        if err and err.get("type") != "notFound":
            print(f"failed {email}: {describe(err)}")
            rc = 1
        else:
            print(f"deleted {email}")
    return rc


def cmd_reset_app_password(args):
    acct = find_account(args.email)
    if not acct:
        raise JmapError(f"account {args.email} not found")
    existing = jmap([["x:AppPassword/get", {"accountId": acct["id"]}, "a"]])
    ids = [p["id"] for p in existing["a"].get("list") or [] if p.get("description") == args.name]
    if ids:
        res = jmap([["x:AppPassword/set", {"accountId": acct["id"], "destroy": ids}, "r"]])
        assert_set_ok(f"app password revoke for {args.email}", res["r"])
    res = jmap([["x:AppPassword/set", {"accountId": acct["id"],
                                       "create": {"a": {"description": args.name}}}, "p"]])
    assert_set_ok(f"app password create for {args.email}", res["p"])
    secret = (res["p"].get("created") or {}).get("a", {}).get("secret")
    if not secret:
        raise JmapError(f"app password create for {args.email} returned no secret")
    print(secret)
    return 0


def cmd_reload(_args):
    res = jmap([["x:Action/set", {"create": {"r": {"@type": "ReloadSettings"}}}, "r"]])
    assert_set_ok("ReloadSettings", res["r"])
    return 0


def _lists():
    res = jmap([
        ["x:MailingList/query", {}, "q"],
        ["x:MailingList/get", {"#ids": {"resultOf": "q", "name": "x:MailingList/query", "path": "/ids"}}, "g"],
    ])
    return res["g"].get("list") or []


def _find_list(address):
    addr = address.strip().lower()
    for lst in _lists():
        if (lst.get("emailAddress") or "").lower() == addr:
            return lst
    return None


def _list_json(lst):
    return {"id": lst["id"], "name": lst.get("name"), "emailAddress": lst.get("emailAddress"),
            "description": lst.get("description"),
            "recipients": sorted(k for k, v in (lst.get("recipients") or {}).items() if v)}


def cmd_lists(_args):
    print(json.dumps([_list_json(lst) for lst in _lists()], indent=2))
    return 0


def cmd_list_get(args):
    lst = _find_list(args.address)
    if not lst:
        return 4
    print(json.dumps(_list_json(lst), indent=2))
    return 0


def cmd_list_create(args):
    local, domain, addr = split_email(args.address)
    if _find_list(addr):
        print("exists")
        return 0
    value = {"name": local, "domainId": domain_id(domain), "description": args.description,
             "recipients": {r.strip().lower(): True for r in args.recipients}}
    res = jmap([["x:MailingList/set", {"create": {"m": value}}, "c"]])
    failed = (res["c"].get("notCreated") or {}).get("m")
    if failed:
        if failed.get("type") == "primaryKeyViolation":
            print("exists")
            return 0
        raise JmapError(f"mailing list create for {addr} failed: {describe(failed)}")
    print("created")
    return 0


def cmd_list_members(args):
    lst = _find_list(args.address)
    if not lst:
        return 4
    value = True if args.add else None
    patch = {"recipients/" + r.strip().lower(): value for r in args.recipients}
    res = jmap([["x:MailingList/set", {"update": {lst["id"]: patch}}, "u"]])
    assert_set_ok(f"mailing list update for {args.address}", res["u"])
    return 0


def cmd_list_delete(args):
    lst = _find_list(args.address)
    if not lst:
        return 4
    res = jmap([["x:MailingList/set", {"destroy": [lst["id"]]}, "x"]])
    assert_set_ok(f"mailing list delete for {args.address}", res["x"])
    return 0


def main(argv):
    p = argparse.ArgumentParser(description="Stalwart v1 JMAP management helper")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping").set_defaults(fn=cmd_ping)
    sub.add_parser("domains").set_defaults(fn=cmd_domains)
    s = sub.add_parser("accounts")
    s.add_argument("--prefix", default="")
    s.set_defaults(fn=cmd_accounts)
    s = sub.add_parser("account-exists")
    s.add_argument("email")
    s.set_defaults(fn=cmd_account_exists)
    s = sub.add_parser("ensure-account")
    s.add_argument("email")
    s.add_argument("--description", default="")
    s.add_argument("--alias", action="append", default=[], help="extra local part on the same domain")
    s.set_defaults(fn=cmd_ensure_account)
    sub.add_parser("delete-accounts").set_defaults(fn=cmd_delete_accounts)
    s = sub.add_parser("reset-app-password")
    s.add_argument("email")
    s.add_argument("name")
    s.set_defaults(fn=cmd_reset_app_password)
    sub.add_parser("reload").set_defaults(fn=cmd_reload)
    sub.add_parser("lists").set_defaults(fn=cmd_lists)
    s = sub.add_parser("list-get")
    s.add_argument("address")
    s.set_defaults(fn=cmd_list_get)
    s = sub.add_parser("list-create")
    s.add_argument("address")
    s.add_argument("description")
    s.add_argument("recipients", nargs="*")
    s.set_defaults(fn=cmd_list_create)
    s = sub.add_parser("list-members")
    s.add_argument("address")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--add", action="store_true")
    g.add_argument("--remove", action="store_true")
    s.add_argument("recipients", nargs="+")
    s.set_defaults(fn=cmd_list_members)
    s = sub.add_parser("list-delete")
    s.add_argument("address")
    s.set_defaults(fn=cmd_list_delete)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except AuthRejected as e:
        print(f"stalwart-jmap: {e}", file=sys.stderr)
        return 3
    except JmapError as e:
        print(f"stalwart-jmap: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
