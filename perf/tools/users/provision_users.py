#!/usr/bin/env python3
import sys
import os
import argparse
import csv
import json
import urllib.request
import urllib.parse
import urllib.error
import subprocess
from typing import Optional, Tuple


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def require_env_not_prod(env: str):
    if env == "prod":
        eprint("Refusing to run provisioning on prod environment")
        sys.exit(1)


def http_request(method: str, url: str, headers=None, data: Optional[bytes] = None) -> Tuple[int, dict, bytes]:
    headers = headers or {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            status = resp.getcode()
            body = resp.read()
            return status, dict(resp.headers), body
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read() if e.fp else b""
    except Exception as e:
        eprint(f"Transport error: {e}")
        return 0, {}, b""


def get_kc_admin_token(base_url: str, realm: str, admin_user: Optional[str], admin_pass: Optional[str],
                       client_id: Optional[str], client_secret: Optional[str]) -> str:
    token_url = f"{base_url}/realms/{realm}/protocol/openid-connect/token"
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    form = {}
    if admin_user and admin_pass:
        form = {
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": admin_user,
            "password": admin_pass,
        }
    elif client_id and client_secret:
        form = {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        }
    else:
        eprint("Must provide either admin username/password or client credentials for Keycloak")
        sys.exit(2)
    data = urllib.parse.urlencode(form).encode("utf-8")
    status, _, body = http_request("POST", token_url, headers, data)
    if status != 200:
        eprint(f"Failed to get admin token (status={status}): {body[:300]!r}")
        sys.exit(3)
    payload = json.loads(body.decode("utf-8"))
    return payload.get("access_token", "")


def kc_find_user(base_url: str, realm: str, token: str, username: str) -> Optional[str]:
    q = urllib.parse.urlencode({"username": username, "exact": "true"})
    url = f"{base_url}/admin/realms/{realm}/users?{q}"
    status, _, body = http_request("GET", url, {"Authorization": f"Bearer {token}"})
    if status != 200:
        eprint(f"Keycloak search failed for {username}: status={status}")
        return None
    users = json.loads(body.decode("utf-8"))
    if not users:
        return None
    return users[0].get("id")


def kc_create_user(base_url: str, realm: str, token: str, username: str) -> Optional[str]:
    url = f"{base_url}/admin/realms/{realm}/users"
    payload = json.dumps({"username": username, "enabled": True, "emailVerified": True}).encode("utf-8")
    status, headers, _ = http_request("POST", url, {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }, payload)
    if status not in (201, 409):  # 409 if exists
        eprint(f"Failed to create Keycloak user {username}: status={status}")
        return None
    if status == 201:
        loc = headers.get("Location", "")
        if loc:
            return loc.rstrip("/").split("/")[-1]
    # If already exists, resolve id
    return kc_find_user(base_url, realm, token, username)


def kc_set_password(base_url: str, realm: str, token: str, user_id: str, password: str) -> bool:
    url = f"{base_url}/admin/realms/{realm}/users/{user_id}/reset-password"
    payload = json.dumps({"type": "password", "value": password, "temporary": False}).encode("utf-8")
    status, _, _ = http_request("PUT", url, {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }, payload)
    return status in (204, 200)


def create_matrix_user(repo_root: str, env_name: str, username: str, password: str) -> bool:
    script = os.path.join(repo_root, "create-matrix-user.sh")
    if not os.path.isfile(script):
        eprint("create-matrix-user.sh not found")
        return False
    cmd = [script, "--env", env_name, "-p", password, username]
    try:
        # Ensure absolute kubeconfig path is available to the child process
        kubeconfig_path = os.path.join(repo_root, f"kubeconfig.{env_name}.yaml")
        child_env = os.environ.copy()
        child_env["KUBECONFIG"] = kubeconfig_path
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env)
        if res.returncode != 0:
            eprint(f"Matrix user creation failed for {username}: {res.stderr.strip()}")
            return False
        return True
    except Exception as e:
        eprint(f"Failed to run matrix create script: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Provision users in Keycloak and Matrix (Synapse) from CSV")
    parser.add_argument("--env", default="dev", choices=["dev", "prod"], help="Target environment (refuses prod)")
    parser.add_argument("--csv", required=True, help="Path to CSV file (username,password)")
    parser.add_argument("--kc-base-url", required=True, help="Keycloak base URL, e.g., https://auth.example.org")
    parser.add_argument("--realm", required=True, help="Keycloak realm name")
    parser.add_argument("--kc-admin-username", help="Keycloak admin username")
    parser.add_argument("--kc-admin-password", help="Keycloak admin password")
    parser.add_argument("--kc-admin-client-id", help="Keycloak admin client id (client credentials)")
    parser.add_argument("--kc-admin-client-secret", help="Keycloak admin client secret")
    args = parser.parse_args()

    require_env_not_prod(args.env)

    # Resolve repo root (two levels up from this script)
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

    token = get_kc_admin_token(
        args.kc_base_url,
        args.realm,
        args.kc_admin_username,
        args.kc_admin_password,
        args.kc_admin_client_id,
        args.kc_admin_client_secret,
    )
    if not token:
        eprint("Could not obtain Keycloak admin token")
        sys.exit(4)

    created_kc = 0
    updated_pw = 0
    created_mx = 0
    failures = 0

    with open(args.csv, newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        for row in reader:
            if not row or len(row) < 2:
                continue
            username = row[0].strip()
            password = row[1].strip()
            if not username or not password:
                continue

            uid = kc_find_user(args.kc_base_url, args.realm, token, username)
            if uid is None:
                uid = kc_create_user(args.kc_base_url, args.realm, token, username)
                if uid:
                    created_kc += 1
                    eprint(f"Created Keycloak user {username}")
                else:
                    failures += 1
                    continue
            if not kc_set_password(args.kc_base_url, args.realm, token, uid, password):
                eprint(f"Failed to set password for {username}")
                failures += 1
                continue
            updated_pw += 1

            if create_matrix_user(repo_root, args.env, username, password):
                created_mx += 1
                eprint(f"Created Matrix user {username}")
            else:
                failures += 1

    print("Provisioning summary:")
    print(f"- Keycloak users created: {created_kc}")
    print(f"- Keycloak passwords set: {updated_pw}")
    print(f"- Matrix users created:   {created_mx}")
    print(f"- Failures:               {failures}")

    sys.exit(0 if failures == 0 else 5)


if __name__ == "__main__":
    main()


