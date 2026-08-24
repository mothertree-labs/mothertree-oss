#!/usr/bin/env python3
"""Functional web-search gate for Open WebUI.

Runs INSIDE the open-webui container (piped to `python3 -` via kubectl exec
by deploy-llm-webui.sh). Verifies, as a role=user account, that a chat
completion with the web_search feature actually performs a search and cites
sources — the exact path that can break silently on image upgrades: the pod
comes up healthy, OIDC works, the model list renders, but search never runs
(e.g. Open WebUI 0.11 only runs the forced-RAG search handler under legacy
function calling; see docs/plans/llm/web-search.md).

Three stages, each failing loudly (non-zero exit fails the deploy):
  1. SearXNG canary — direct JSON query, isolates "search backend down /
     JSON API broken" from Open WebUI wiring failures.
  2. Provision a role=user gate account through Open WebUI's own model
     layer and mint a JWT with the pod's WEBUI_SECRET_KEY. role=user (not
     admin) so permission-gate regressions are caught too.
  3. Chat completion with features.web_search=true — assert the response
     carries a non-empty `sources` array. The assertion is structural
     (sources present), not on answer text, so LLM nondeterminism does not
     flake the gate: with the deterministic forced-RAG path wired
     correctly, search always runs and always yields sources.

Env (set by the deploy script / container):
  GATE_MODEL         model to chat with (falls back to DEFAULT_MODELS)
  SEARXNG_QUERY_URL  from the container env (open-webui-tenant.yaml.tpl)
  ENABLE_WEB_SEARCH  must be "true" in the container env
  WEBUI_SECRET_KEY   from container env, or auto-read from the key file
"""

import asyncio
import inspect
import json
import os
import sys
import time
import uuid
from datetime import timedelta

import requests

GATE_EMAIL = "ci-websearch-gate@invalid.local"
GATE_QUERY = "What is the current population of France? Answer in one short sentence."
CHAT_URL = "http://localhost:8080/api/chat/completions"
SECRET_KEY_FILES = (
    "/app/backend/.webui_secret_key",
    "/app/backend/data/.webui_secret_key",
)


def fail(msg):
    print(f"GATE FAIL: {msg}", flush=True)
    sys.exit(1)


async def acall(fn, *args, **kwargs):
    # Open WebUI's model layer is sync on 0.9.x and async on 0.11+ —
    # await only when the call actually returns an awaitable.
    result = fn(*args, **kwargs)
    if inspect.isawaitable(result):
        result = await result
    return result


def searxng_canary(searxng_url):
    base = searxng_url.split("?")[0]
    last = ""
    for attempt in range(1, 4):
        try:
            r = requests.get(
                base,
                params={"q": "current population of France", "format": "json"},
                timeout=30,
            )
            results = r.json().get("results", []) if r.ok else []
            if results:
                print(f"searxng canary OK: HTTP {r.status_code}, {len(results)} results")
                return
            last = f"HTTP {r.status_code}, {len(results)} results"
        except Exception as e:  # noqa: BLE001 — any transport/parse error is a retry
            last = repr(e)
        print(f"  searxng canary attempt {attempt}/3 failed ({last}), retrying in 5s")
        time.sleep(5)
    fail(
        f"SearXNG returned no usable results after 3 attempts ({last}) — "
        "search backend down, JSON API disabled, or upstream engines unreachable"
    )


async def run(model):
    from open_webui.models.users import Users
    from open_webui.utils.auth import create_token

    user = await acall(Users.get_user_by_email, GATE_EMAIL)
    if user is None:
        user = await acall(
            Users.insert_new_user,
            id=str(uuid.uuid4()),
            name="ci-websearch-gate",
            email=GATE_EMAIL,
            role="user",
        )
    if user is None:
        fail(f"could not provision gate user {GATE_EMAIL}")
    print(f"gate user ready: {user.id} (role={user.role})")
    try:
        token = create_token(data={"id": user.id}, expires_delta=timedelta(minutes=10))
    except TypeError:
        # Older create_token without expires_delta support.
        token = create_token(data={"id": user.id})

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": GATE_QUERY}],
        "features": {"web_search": True},
        "stream": False,
    }
    resp = None
    for attempt in range(1, 3):
        resp = requests.post(
            CHAT_URL,
            headers={"Authorization": f"Bearer {token}"},
            json=payload,
            timeout=240,
        )
        if resp.status_code == 200:
            break
        print(
            f"  chat completion attempt {attempt}/2: HTTP {resp.status_code} "
            f"{resp.text[:300]}"
        )
        time.sleep(10)
    if resp is None or resp.status_code != 200:
        fail(f"chat completion failed: HTTP {resp.status_code} {resp.text[:300]}")

    try:
        body = resp.json()
    except ValueError:
        fail(f"chat completion returned non-JSON body: {resp.text[:300]}")

    try:
        answer = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        answer = ""
    print(f"answer: {json.dumps(answer[:200])}")

    sources = body.get("sources") or []
    if not sources:
        fail(
            "chat completion returned NO sources — web search did not run. "
            "The wiring silently regressed (permission gate, function-calling "
            "mode, or search handler); see docs/plans/llm/web-search.md. "
            f"Response keys: {sorted(body.keys())}"
        )
    print(f"GATE PASS: web search ran, {len(sources)} source(s) cited")

    # Best-effort cleanup so the gate account doesn't linger in the user list.
    try:
        await acall(Users.delete_user_by_id, user.id)
    except Exception as e:  # noqa: BLE001 — cleanup is non-fatal
        print(f"note: gate user cleanup failed ({e!r}) — harmless, reused next run")


def main():
    if os.environ.get("ENABLE_WEB_SEARCH") != "true":
        fail("ENABLE_WEB_SEARCH != true in the container env — web search is expected wired on every deployment")
    searxng_url = os.environ.get("SEARXNG_QUERY_URL", "")
    if not searxng_url:
        fail("SEARXNG_QUERY_URL not set in the container env")
    model = os.environ.get("GATE_MODEL") or os.environ.get("DEFAULT_MODELS") or ""
    if not model:
        fail("no model to test with (GATE_MODEL / DEFAULT_MODELS both unset)")

    # WEBUI_SECRET_KEY must be in the env BEFORE open_webui modules are
    # imported (open_webui.env hard-fails without it). Depending on version
    # and start method it is either a container env var or auto-generated
    # into a key file by start.sh.
    if not os.environ.get("WEBUI_SECRET_KEY"):
        for path in SECRET_KEY_FILES:
            if os.path.exists(path):
                with open(path) as f:
                    os.environ["WEBUI_SECRET_KEY"] = f.read().strip()
                break
    if not os.environ.get("WEBUI_SECRET_KEY"):
        fail(f"WEBUI_SECRET_KEY not in env and no key file found in {SECRET_KEY_FILES}")

    searxng_canary(searxng_url)
    asyncio.run(run(model))


if __name__ == "__main__":
    main()
