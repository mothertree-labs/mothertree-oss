## Why the model can't browse on its own

No local LLM (including self-hosted Llama) can access the internet by itself.
Open WebUI has a built-in **Web Search** feature that sits between the model and the
internet:

1. Your prompt goes to an LLM "task model" (can be the same Llama model), which generates a search query.

2. Open WebUI sends that query to a **search provider**, and gets back results/snippets.

3. It fetches/extracts page content and injects it into the context as RAG.

4. Your model writes the final answer using that injected context.

So the model never touches the internet directly — Open WebUI's backend does, via
a search API.

## Recommended plan

> Superseded (2026-08-14): implemented with **self-hosted SearXNG**, deployed via
> env vars in the tenant template — see "Implementation status" below. The Brave
> + Admin Panel path described here is retained as the original design/history;
> do not follow it for the current deployment.

Use **Brave Search API** to start — free tier of ~2,000 searches/month, minimal
setup, decent quality. Upgrade to a paid provider later only if you outgrow the
free tier.

### Steps to enable

1. Sign up for a Brave Search API key.

2. Log in to Open WebUI with an **admin** account.

3. Click your profile icon/name (bottom-left corner).

4. Select **Admin Panel**.

5. Go to the **Settings** tab (top of the page).

6. Click **Web Search** in the left sidebar.

7. Toggle **Web Search** on.

8. Select **brave** from the Web Search Engine dropdown.

9. Paste your Brave API key into the API Key field.

10. Save.

11. In a chat, click the **+** button in the prompt box and enable "Web Search" for that message (or set it as always-on for a model).

If you hit rate limits on a free-tier key, set the environment variable
`WEB_SEARCH_CONCURRENT_REQUESTS=1` so requests go out one at a time instead of
in parallel.

> Note: if you don't see "Admin Panel" as an option, your logged-in user isn't
> set as admin. The first account created on a fresh Open WebUI instance is
> admin by default; this can be changed under Admin Panel → Users.

---

## Alternatives

### Self-hosted, free

* **SearXNG** — open-source metasearch engine you run yourself (Docker container alongside Open WebUI). Aggregates results from Google, Bing, DuckDuckGo, etc. Free and private, but setup is fiddly:

  * Needs `json` added to `formats` in SearXNG's `settings.yml`, or you'll get 403 errors.

  * Needs a real `USER_AGENT` set, or content extraction can silently fail (bot detection).

  * Note (verified 2026-08-16): the `searxng/searxng-docker` helper repo (Docker Compose setup) was archived on 2026-03-28, but the main `searxng/searxng` repo is alive and actively maintained (a commit landed 2026-08-14; the pinned image `2026.8.5-1689cb1b5` comes from its release train). Older tutorials are still worth checking for staleness, but the project is not dead.

### Paid / managed APIs

* **Tavily / Exa / Linkup** — search APIs built specifically for LLM/RAG use; return clean structured results instead of raw HTML.

* **Serper / SerpAPI / Serply** — essentially "Google SERP as an API," they handle the scraping/anti-bot problem for you.

* **Google Programmable Search (PSE)**, **Bing Search API**, **Kagi**, **Yandex**, **Yacy**, **Mojeek**, **[you.com](https://you.com)** — all supported natively as dropdown options in Open WebUI's Web Search settings.

### How ChatGPT / Codex etc. do it (and avoid CAPTCHAs)

They don't scrape `google.com/search` in a headless browser — that's exactly
what triggers CAPTCHAs. Instead:

* **Licensed search APIs** — ChatGPT's browsing historically ran on the **Bing Search API** via a commercial agreement with Microsoft: sanctioned, high-volume access, no scraping involved.

* **Own crawler + index** — OpenAI also runs its own crawler (`OAI-SearchBot`) and has direct content-licensing deals with publishers, so part of "search" is really querying their own index built from permitted crawling.

* Commercial products like Tavily/Exa/Serper exist precisely to be "the thing that deals with rate limits, JS rendering, and anti-bot detection so your app doesn't have to."

The pattern at every scale: never scrape the consumer search page directly —
pay for or license API-level access (Bing/Brave/Google PSE), or self-host a
metasearch aggregator (SearXNG) built to behave as a legitimate client rather
than a browser impersonating a human.


---

## Implementation status (2026-08-14)

> Decision change: provider is **SearXNG** (self-hosted, shared), not Brave.

### Live dev trial state (2026-08-14) — superseded by the codified templates
Note (2026-08-16): the dev cluster was re-deployed from the committed template
(which does not yet contain the env vars), wiping the live wiring below; the
trial `deployment/searxng` still runs in `infra-llm` under the same name as the
codified manifest, so the codified deploy will adopt it — no duplicate. The
"Permanent repo changes" section is the durable source of truth.

Shared SearXNG in `infra-llm` (behaves like shared Ollama infra):

- `deployment/searxng` — image `searxng/searxng:2026.8.5-1689cb1b5`
- `service/searxng` — `infra-llm:8080`, serves JSON API at `/search`
- `secret/searxng-settings` — `settings.yml` with `use_default_settings: true`
  and `search.formats: [html, json]` (Open WebUI requires the `json` format)
- `/healthz` readiness endpoint

Open WebUI wiring (`tn-mothertree-llm` deployment `open-webui`, image
`openwebui/open-webui:0.9.6`):

- `ENABLE_WEB_SEARCH=true`
- `WEB_SEARCH_ENGINE=searxng`
- `SEARXNG_QUERY_URL=http://searxng.infra-llm.svc.cluster.local:8080/search`
- `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true`
- `BYPASS_MODEL_ACCESS_CONTROL=true` — see "Model visibility for regular
  users" below

### Operational caveats

- `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE`, and `SEARXNG_QUERY_URL` are
  **PersistentConfig**-backed in Open WebUI: the env value only applies if the
  setting was never saved via the Admin Panel (a saved value wins, stored in
  webui.db). Nothing in the tenant template or deploy scripts saves them, so
  CI/env wins unless an operator touches the Admin Panel Web Search page. On
  dev the DB is emptyDir anyway, so any such override evaporates on restart.
- All tenants share the single `infra-llm` SearXNG instance (each tenant runs
  its own open-webui, but they all point at the same `searxng` service).
  SearXNG's `server.limiter` is off by default; upstream engines may
  throttle/rate-limit shared egress, visible as intermittent 429s or empty
  results. Watch it if usage grows.

### Why `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true` (0.9.6 bug workaround)

In Open WebUI 0.9.6 the web-search RAG path (embedding results into an ephemeral
`web-search-*` Chroma collection and retrieving them) is broken: `get_sources_from_items`
has no branch for file items with `type == 'web_search'`, so their `collection_name`
is dropped by the retrieval access-control logic unless the global
`BYPASS_RETRIEVAL_ACCESS_CONTROL` is set — an all-or-nothing flag that also skips
the pre-checks for file/knowledge-base collections.

The narrow bypass (`BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true`) feeds the
fetched page texts directly into the chat context as sources instead of going
through the vector store. Result: same visible behavior, no weakening of
file/KB retrieval access control, no per-search vector-store churn. Verified
end-to-end, not just on the raw search API.

### Verified end-to-end (chat + sources + citation)

Request: `POST /api/chat/completions` with `features.web_search: true` on
`llama3.2:1b`; response contained:

- `sources[]` with real URLs — e.g. Wikipedia/Canberra, australia.com,
  britannica.com, worldometers population page
- `usage.input_tokens` 2048 (vs ~40 without search context) — context
  injection confirmed
- model answer citing the injected sources (e.g. Australia 2026 population,
  OpenAI CEO = Sam Altman)

Also verified in-pod: `open_webui.retrieval.web.searxng.search_searxng` returns
real results, and SearXNG itself returns JSON for sample queries.

### Model visibility for regular users (0.9.6 bug workaround)

Open WebUI 0.9.6 filters `GET /api/models` for `role == 'user'` through
per-model access control (`open_webui/routers/openai.py`:
`if user.role == 'user' and not BYPASS_MODEL_ACCESS_CONTROL: models['data'] =
await get_filtered_models(...)`). `check_model_access` raises 403 for any
model that is not REGISTERED in Open WebUI's model registry and granted to the
user — and plain Ollama models are never registered. Result: regular users see
an **empty model list** (admins are unaffected; the first user of a fresh DB
becomes admin, which is why it wasn't obvious). Fixed with the documented
escape hatch `BYPASS_MODEL_ACCESS_CONTROL=true` — per-model grants are not used
on this shared single-model setup.

Verified by minting a token as a role=`user` account via the pod's own
`WEBUI_SECRET_KEY`: `/api/models` returned `[]` before the flag and
`['llama3.2:1b', 'arena-model']` after.

### Upgrade to 0.11.0 (applied 2026-08-24)

Bumped the image to `openwebui/open-webui:0.11.0` and verified the wiring live
on the dev cluster (role=user JWT, the same method as above):

- **Permission gate is open by default on 0.11.0** — `features.web_search`
  defaults to `true` in `USER_PERMISSIONS_FEATURES_WEB_SEARCH` and in the
  seeded `user.permissions` config; a role=user token got real SearXNG results
  from `/api/v1/retrieval/process/web/search` (HTTP 200). No grant wiring
  needed (the "admins must grant it" concern in the 0.9.6-era note above did
  not materialize on 0.11.0).
- **The forced-RAG path only runs under legacy function calling** —
  confirmed in `utils/middleware.py` (`function_calling == 'legacy'` gate).
  With native FC (0.11's default), web search delegates to the injected
  `search_web` tool. The pinned model (`llama3.2:1b`) cannot reliably emit
  native `tool_calls` when the whole builtin suite (23 specs, incl. memory /
  notes / calendar…) is injected — in testing it degraded to legacy
  `<|python_tag|>` text and search silently never ran. With
  `function_calling=legacy` the deterministic SearXNG handler runs: verified
  end-to-end as role=user (results fetched, sources + citations, correct
  2026 population answer).
- **Wiring applied**: `DEFAULT_MODEL_PARAMS='{"function_calling": "legacy"}'`
  in `open-webui-tenant.yaml.tpl` (seeds fresh DBs) plus an idempotent
  `models.default_params` upsert in `deploy-llm-webui.sh` step 10 (the
  PersistentConfig DB row shadows the env on existing PVC-backed installs).
- `BYPASS_MODEL_ACCESS_CONTROL=true` still required on 0.11.0 — same
  role==user /api/models filter exists in `routers/openai.py`.
- `OLLAMA_DEFAULT_MODELS` removed from the template — dead in both 0.9.6 and
  0.11.0 source (`DEFAULT_MODELS` is the live key).

### Permanent repo changes (working tree, uncommitted — status 2026-08-16)
All changes below are applied to the working tree on branch
`feat/Web-Search-in-Open-WebUI` but **not committed yet**; CI has not deployed
them (the 2026-08-16 re-deploy ran the committed template, hence the wiped live
env vars). Commit + push + open/update the PR → the pipeline deploys them.

1. **Manifests** — `apps/manifests/llm/searxng.yaml.tpl` (Deployment + Service)
   and `apps/manifests/llm/searxng-settings.yaml.tpl` (Secret, split because
   kubectl client-side apply always reports `configured` for a stringData
   Secret, which would restart SearXNG on every deploy). Settings use
   `use_default_settings: true` + `search.formats: [html, json]`; the Opaque
   Secret needs `server.secret_key` (SearXNG refuses the default
   `ultrasecretkey`), injected by `deploy-llm.sh` as a stable generated key.
2. **`apps/deploy-llm.sh`** — deploys SearXNG into shared `infra-llm` after
   Ollama: generate-or-reuse secret key, apply settings Secret untracked with
   content-diff change detection, Deployment/Service under the change tracker,
   rollout wait + `/healthz` probe.
3. **`apps/manifests/llm/open-webui-tenant.yaml.tpl`** — five new env vars:
   `ENABLE_WEB_SEARCH=true`, `WEB_SEARCH_ENGINE=searxng`,
   `SEARXNG_QUERY_URL=http://searxng.infra-llm.svc.cluster.local:8080/search`,
   `BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=true`,
   `BYPASS_MODEL_ACCESS_CONTROL=true`. No `deploy-llm-webui.sh` logic change
   needed — the template carries the constants.
4. **CI deploy path (verified in pipeline files)** — both dev workflows trigger
   on `pull_request` and `push:main`:
   - `deploy-dev-prep` → `ci-deploy.sh` → `scripts/deploy_infra` →
     `apps/deploy-llm.sh` (pre-existing unconditional call, ~line 830) →
     Ollama + SearXNG in `infra-llm`
   - `deploy-dev-llm` (depends on prep) → `ci-deploy-app.sh dev llm` →
     `deploy-llm-webui.sh` per tenant → the template env vars land on the webui
   No merge needed for dev; the PR itself deploys it.
5. **Idempotence** — manual re-runs (2026-08-14): `deploy-llm.sh -e dev` no
   SearXNG restart; `deploy-llm-webui.sh -e dev -t mothertree` reports
   `unchanged` on the second pass; end-to-end chat with `features.web_search`
   re-verified after the codified deploy (sources + citation, e.g. destatis.de).
6. **CHANGELOG.md** — `### Added` entry under Unreleased.
7. **`.gitignore`** — `.rodney/` ignored (local browser profile holds live
   session cookies; must not be committed).

Known pre-existing quirk (untouched): the `open-webui-oidc` Secret in
`open-webui-tenant.yaml.tpl` triggers `mt_apply`'s change flag on every
`deploy-llm-webui.sh` run (same stringData-apply behavior), so Open WebUI
restarts on each deploy. Not changed here — out of scope for this feature.

---

## The deploy gate is advisory (changed 2026-09-10)

`apps/websearch-gate/websearch-gate.py` runs after every Open WebUI deploy. It
used to fail the deploy on any non-zero exit. That conflated two questions that
need different answers, and on 2026-09-10 it took the entire PR queue down —
#658, #657, #625 and #639 all failed `deploy-dev-llm` for a reason none of them
caused.

### Why: datacenter egress IPs are not welcome at free search engines

`ensure-dev-cluster` had rebuilt the on-demand dev cluster mid-pipeline, so it
came up on a new Linode egress IP. Measured on that cluster, immediately after a
clean `rollout restart deploy/searxng -n infra-llm`:

| probe | results | engines refusing |
|---|---|---|
| 1 | 30 | duckduckgo CAPTCHA, startpage CAPTCHA |
| 2 | 20 | + brave "too many requests" |
| 3 | 20 | + brave suspended, startpage suspended |

**duckduckgo and startpage refuse from the very first query on a fresh node** —
that is the egress IP, not accumulated state, and no restart or retry fixes it.
brave dies within a couple of queries. That leaves google-cse carrying the
deploy alone, and a two-tenant deploy spends ~10 queries (each tenant runs up to
3 canary + up to 2 chat searches), so it too hits "too many requests" and SearXNG
starts answering `HTTP 200` with an empty result set.

The `rollout restart` recipe still works, but it buys roughly one deploy.

### The contract

The script now reports; `deploy-llm-webui.sh` decides.

| exit | meaning | deploy |
|---|---|---|
| 0 | search ran and cited sources | continue |
| 2 | **cannot run** — engines refused, Ollama down, model/key missing | warn, continue |
| 3 | **regression** — our deployment fails a test that could run | warn loudly, continue |
| 90 | exited 0 but printed no `GATE PASS` — nothing was actually tested | warn, continue |
| * | harness broke (incl. **1**) — no verdict was reached | warn, continue |

The distinction that matters: exit 2 says *nothing* about our wiring, so it must
never block. Exit 3 is the 0.9.6→0.11 class of silent breakage this gate exists
to catch — the canary is what separates them, which is why the canary result has
to be carried forward rather than the canary simply being downgraded.

**The regression verdict is 3, not 1, on purpose.** The gate is delivered over
`kubectl exec`, and kubectl reports its own transport failures — no such pod, API
unreachable, exec denied — as exit 1. Had the verdict shared that code, a
connection problem would be announced as "web search is broken on this
deployment": the exact cannot-run/failed confusion this taxonomy removes.

A non-pass also downgrades the closing "Open WebUI deployed" line from green to
a warning, so a log that no longer goes red cannot end looking clean.

**Exit 0 is not taken at face value.** `kubectl exec -i` delivering empty or
truncated stdin leaves `python3 -` with nothing to execute: it reads EOF and
exits 0, and the deploy would report a pass having tested nothing — the same
class as the Roundcube schema-verify false negative, where an empty result from
`kubectl run -i` was mistaken for an answer. A pass must therefore be
corroborated by the gate's own `GATE PASS:` line; without it the result becomes
90 (no verdict) rather than success.

**Two things stay fatal**, because they are bugs rather than legitimate reasons
the test cannot run: `WEBSEARCH_GATE_ENFORCE=1` with a regression, and a missing
or unreadable gate script (a failed input redirect is exit 1, which now only
warns — so without that pre-flight check a moved file or a mis-resolved
`REPO_ROOT` would silently turn the gate into a permanent no-op).

**Enforcement is per-environment (since 2026-09-11).** `deploy-llm-webui.sh`
derives it from `MT_ENV`: **fatal on `prod` and `prod-eu`, advisory on dev**, with
an explicit `WEBSEARCH_GATE_ENFORCE` in the environment overriding either way.

The split follows the measurement, not a guess. Prod and prod-eu have stable
egress IPs and passed cleanly on 2026-09-10/11 (canary returning 29-31 results),
so a regression there is real and should block. Dev is rebuilt on demand onto
fresh Linode IPs that duckduckgo and startpage CAPTCHA from the first query
(#661) — which is exactly what let a hard gate take the whole PR queue down.

It is derived in the script rather than set in `.woodpecker/` so a standalone
`./apps/deploy-llm-webui.sh -e prod -t <tenant>` behaves like the pipeline. An
`MT_ENV` outside the allowlist stays advisory and says so in the log, rather than
auto-arming a gate for an environment nobody has measured.

**How the failure actually reaches the pipeline: exit 20.** `deploy-llm-webui.sh`
exits **20** when an enforced gate fails, and that specific code is what makes
enforcement real. `create_env` deliberately treats a generic non-zero from this
script as non-fatal ("had issues, continuing") because of #446, where a stuck
Ollama init made deploys flaky — so a bare `exit 1` would be swallowed there and
`deploy-prod` would go green with web search broken. `create_env` propagates 20
and only 20; `ci/scripts/ci-deploy-app.sh` calls the script bare under `set -e`
and so propagates it too. If you are looking at a red prod deploy, **exit 20 from
this script means the web-search gate failed and enforcement is on** — not that
the deploy script itself broke.

### Making the backend dependable (not done)

The durable fix is upstream of the gate: give SearXNG engines that answer from a
datacenter IP — API-keyed engines (Brave Search API, a real google-cse quota) or
engines that do not CAPTCHA datacenter ranges (mojeek, wikipedia, qwant) — rather
than relying on the default free scraped set. Requires new secrets and a cost
decision. A cheaper partial: hoist the canary out of the per-tenant loop, since
SearXNG is a single shared deployment in `infra-llm` whose health cannot differ
between tenants, and the duplicate canaries are ~half the query burn.
