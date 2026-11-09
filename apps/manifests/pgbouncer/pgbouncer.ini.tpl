[databases]
; Wildcard entry — forwards any database name to the PG VM.
; New tenant databases on the PG VM work immediately without PgBouncer redeployment.
* = host=${PG_VM_TAILSCALE_IP} port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432

; Session mode is safest — Nextcloud uses prepared statements and Keycloak uses
; advisory locks, both of which require session-level PostgreSQL features.
pool_mode = session

max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE}
reserve_pool_timeout = 3

; Use auth_query to look up credentials from PostgreSQL directly.
; This avoids maintaining a separate userlist.txt — new database users
; on the PG VM are immediately reflected in PgBouncer.
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
; auth_user: the user PgBouncer connects as to run auth_query.
; Must exist in auth_file (for bootstrapping) and have SELECT on pg_shadow in PostgreSQL.
auth_user = pgbouncer
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1
; Run auth_query in the `postgres` database, not in the database the client
; asked for. pg_shadow is cluster-wide, and every db-init Job REVOKEs CONNECT
; FROM PUBLIC on the database it creates — so without this, auth_user needs a
; per-database GRANT CONNECT that no deploy step creates (dev/prod only have
; it from hand grants; a fresh PostgreSQL fails every login with "permission
; denied for database"). PgBouncer >= 1.20.
auth_dbname = postgres

; Admin/stats access (localhost only)
admin_users = pgbouncer
stats_users = pgbouncer

; Allow extra startup parameters that some clients send (e.g. Rust's tokio-postgres)
ignore_startup_parameters = extra_float_digits

; Logging
log_connections = 0
log_disconnections = 0
log_pooler_errors = 1

; Timeouts
server_idle_timeout = 600
server_connect_timeout = 15
server_login_retry = 3
client_idle_timeout = 0
client_login_timeout = 60

; TLS to PostgreSQL VM (optional, disabled by default — traffic is inside WireGuard tunnel)
; server_tls_sslmode = prefer
