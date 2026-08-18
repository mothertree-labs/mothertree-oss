apiVersion: v1
kind: Secret
metadata:
  name: searxng-settings
  namespace: infra-llm
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/managed-by: mothertree
    mothertree/component: llm
type: Opaque
# settings.yml is mounted at /etc/searxng/settings.yml (SearXNG's default
# location) and layered over the image's built-in defaults via
# use_default_settings: true. See docs/plans/llm/web-search.md.
stringData:
  settings.yml: |
    use_default_settings: true
    # server.secret_key must differ from the image default "ultrasecretkey" or
    # SearXNG refuses to start. deploy-llm.sh injects a stable random key
    # (generated once, reused on later deploys — same pattern as ollama-s3).
    server:
      secret_key: "${SEARXNG_SECRET_KEY}"
    # Open WebUI queries the search endpoint with ?format=json; SearXNG's
    # default formats only serve HTML, and the JSON API answers 403 without
    # json listed here.
    search:
      formats:
        - html
        - json
