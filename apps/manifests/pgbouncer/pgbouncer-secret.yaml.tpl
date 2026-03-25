---
# PgBouncer userlist — bootstrap credentials for auth_query.
# The pgbouncer user must exist in PostgreSQL with SELECT on pg_shadow.
apiVersion: v1
kind: Secret
metadata:
  name: pgbouncer-userlist
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
type: Opaque
stringData:
  userlist.txt: |
    "pgbouncer" "${PGBOUNCER_AUTH_PASSWORD}"
    "postgres" "${PG_SUPERUSER_PASSWORD}"
---
# Tailscale pre-authenticated key for mesh connectivity
apiVersion: v1
kind: Secret
metadata:
  name: pgbouncer-tailscale-auth
  namespace: ${NS_DB}
  labels:
    app: pgbouncer
type: Opaque
stringData:
  TS_AUTHKEY: "${TAILSCALE_AUTHKEY}"
