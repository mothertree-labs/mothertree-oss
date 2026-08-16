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

  * The official SearXNG GitHub repo was archived in late May 2026, so some older tutorials are now broken — use an up-to-date guide.

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

Verified by minting a token as the affected account (`marek.dev@…`, role
`user`) via the pod's own `WEBUI_SECRET_KEY`: `/api/models` returned `[]`
before the flag and `['llama3.2:1b', 'arena-model']` after.

### Findings on newer images (why not bumping yet)

0.11.0 (2026-07-27) changed the web-search trigger: `features.web_search` is now
permission-gated (admins must grant it to non-admin users) and the forced RAG
path only runs with `metadata.params.function_calling == 'legacy'` (native
function calling delegates to a `web_search` tool instead). Making web search
work for regular users on 0.11 therefore needs explicit permission + tool wiring
that is outside this change. 0.9.6 stays as the pinned image.

### Test users (dev only)

Keycloak realm `docs`:

- `test-websearch` / `TestWebSearch1!` (id `fc990f19-0588-4bbd-b90e-fe4acd1e8c14`)
  — used for OIDC login during verification; the first user of a fresh DB,
  so role drifts to admin.
- `marek-webui` / `Marek-LLM-Dev-2026!` — the everyday dev login for
  `llm.dev.mother-tree.org`, role `docs-user` (non-admin, the realistic path:
  sees both models and can chat, verified manually on 2026-08-14).

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
