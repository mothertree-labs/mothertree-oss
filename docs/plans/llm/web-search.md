## Why the model can't browse on its own

No local LLM (including self-hosted Llama) can access the internet by itself.\
Open WebUI has a built-in **Web Search** feature that sits between the model and the\
internet:

1. Your prompt goes to an LLM "task model" (can be the same Llama model), which generates a search query.

2. Open WebUI sends that query to a **search provider**, and gets back results/snippets.

3. It fetches/extracts page content and injects it into the context as RAG.

4. Your model writes the final answer using that injected context.

So the model never touches the internet directly — Open WebUI's backend does, via\
a search API.

## Recommended plan

Use **Brave Search API** to start — free tier of ~2,000 searches/month, minimal\
setup, decent quality. Upgrade to a paid provider later only if you outgrow the\
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

If you hit rate limits on a free-tier key, set the environment variable\
`WEB_SEARCH_CONCURRENT_REQUESTS=1` so requests go out one at a time instead of\
in parallel.

> Note: if you don't see "Admin Panel" as an option, your logged-in user isn't\
> set as admin. The first account created on a fresh Open WebUI instance is\
> admin by default; this can be changed under Admin Panel → Users.

***

## Alternatives

### Self-hosted, free

* **SearXNG** — open-source metasearch engine you run yourself (Docker container alongside Open WebUI). Aggregates results from Google, Bing, DuckDuckGo, etc. Free and private, but setup is fiddly:

  * Needs `json` added to `formats` in SearXNG's `settings.yml`, or you'll get 403 errors.

  * Needs a real `USER_AGENT` set, or content extraction can silently fail (bot detection).

  * The official SearXNG GitHub repo was archived in late May 2026, so some older tutorials are now broken — use an up-to-date guide.

### Paid / managed APIs

* **Tavily / Exa / Linkup** — search APIs built specifically for LLM/RAG use; return clean structured results instead of raw HTML.

* **Serper / SerpAPI / Serply** — essentially "Google SERP as an API," they handle the scraping/anti-bot problem for you.

* **Google Programmable Search (PSE)**, **Bing Search API**, **Kagi**, **Yandex**, **Yacy**, **Mojeek**, **[you.com](http://you.com)** — all supported natively as dropdown options in Open WebUI's Web Search settings.

### How ChatGPT / Codex etc. do it (and avoid CAPTCHAs)

They don't scrape `google.com/search` in a headless browser — that's exactly\
what triggers CAPTCHAs. Instead:

* **Licensed search APIs** — ChatGPT's browsing historically ran on the **Bing Search API** via a commercial agreement with Microsoft: sanctioned, high-volume access, no scraping involved.

* **Own crawler + index** — OpenAI also runs its own crawler (`OAI-SearchBot`) and has direct content-licensing deals with publishers, so part of "search" is really querying their own index built from permitted crawling.

* Commercial products like Tavily/Exa/Serper exist precisely to be "the thing that deals with rate limits, JS rendering, and anti-bot detection so your app doesn't have to."

The pattern at every scale: never scrape the consumer search page directly —\
pay for or license API-level access (Bing/Brave/Google PSE), or self-host a\
metasearch aggregator (SearXNG) built to behave as a legitimate client rather\
than a browser impersonating a human.

