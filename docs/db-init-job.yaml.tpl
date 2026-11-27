apiVersion: batch/v1
kind: Job
metadata:
  name: docs-db-init
  namespace: docs
  labels:
    app.kubernetes.io/name: docs
    app.kubernetes.io/part-of: mother-tree
spec:
  backoffLimit: 1
  # Matches the synapse/stalwart/roundcube db-init Jobs. Without it a completed
  # Job persists forever and the next deploy of this tenant fails with
  # `AlreadyExists` -- which is exactly what broke pipeline 2173 (#667).
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: docs
        app.kubernetes.io/part-of: mother-tree
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:18
          imagePullPolicy: IfNotPresent
          env:
            - name: PGHOST
              value: "${PG_HOST}"
            - name: PGPORT
              value: "5432"
            - name: PGUSER
              value: "postgres"
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: postgres-password
            - name: DOCS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: docs-secrets
                  key: DATABASE_PASSWORD
            - name: DB_NAME
              value: "${DOCS_DB_NAME}"
            - name: DB_USER
              value: "${TENANT_DB_USER}"
            # Collaboration server (yhub, impress >= 6): its own database AND
            # its own non-superuser role (same name), so the internet-facing
            # yhub never holds the tenant role, which is a superuser and owns
            # the Docs database. Schema is created by docs-yhub-init-db.
            - name: YHUB_DB_NAME
              value: "${DOCS_YHUB_DB_NAME}"
            - name: YHUB_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: docs-yhub
                  key: YHUB_DB_PASSWORD
            - name: KEYCLOAK_DB_PASSWORD
              value: "${KEYCLOAK_DB_PASSWORD}"
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              echo "=== Docs Database Initialization ==="
              echo "Database name: $DB_NAME"
              echo "Database user: $DB_USER"
              
              # Escape single quotes in password for SQL literal
              ESC_PW=$(printf "%s" "$DOCS_PASSWORD" | sed "s/'/''/g")

              # Ensure per-tenant role exists (e.g., docs_example)
              ROLE_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" || true)
              if [ "$ROLE_EXISTS" != "1" ]; then
                echo "Creating role $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN SUPERUSER";
              else
                # Grant superuser if role already exists (needed for migrations that create C functions)
                psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH SUPERUSER";
              fi
              # Ensure password set for this tenant's user only
              psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH PASSWORD '$ESC_PW'";

              # Ensure database exists (tenant-specific name)
              DB_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" || true)
              if [ "$DB_EXISTS" != "1" ]; then
                echo "Creating database '$DB_NAME' with owner '$DB_USER'..."
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\"";
              else
                echo "Database '$DB_NAME' already exists, ensuring ownership..."
                psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\"";
              fi

              # Revoke default PUBLIC connect privilege so other tenant users cannot connect
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$DB_NAME\" FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"";

              # Grants in docs database for per-tenant user
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$DB_USER\"";
              
              # Collaboration server database (impress >= 6) and its own role.
              # The role is NOSUPERUSER NOCREATEDB NOCREATEROLE and owns only
              # this database. CONNECT is revoked from PUBLIC; the tenant role
              # is a superuser and bypasses that, so this protects the
              # tenant's data from yhub, not yhub's data from the tenant role.
              : "${YHUB_DB_NAME:?YHUB_DB_NAME must be set}" "${YHUB_DB_PASSWORD:?YHUB_DB_PASSWORD must be set (docs-yhub Secret)}"
              [[ "$YHUB_DB_NAME" =~ ^[a-z0-9_]+$ ]] || { echo "Refusing unexpected yhub db/role name '$YHUB_DB_NAME'"; exit 1; }
              YHUB_ROLE="$YHUB_DB_NAME"
              ESC_YPW=$(printf "%s" "$YHUB_DB_PASSWORD" | sed "s/'/''/g")
              if [ "$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$YHUB_ROLE'" || true)" != "1" ]; then
                echo "Creating role $YHUB_ROLE..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$YHUB_ROLE\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT";
              fi
              psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$YHUB_ROLE\" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '$ESC_YPW'";
              YHUB_DB_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname='$YHUB_DB_NAME'" || true)
              if [ "$YHUB_DB_EXISTS" != "1" ]; then
                echo "Creating database '$YHUB_DB_NAME' with owner '$YHUB_ROLE'..."
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$YHUB_DB_NAME\" OWNER \"$YHUB_ROLE\"";
              else
                psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$YHUB_DB_NAME\" OWNER TO \"$YHUB_ROLE\"";
              fi
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$YHUB_DB_NAME\" FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$YHUB_DB_NAME\" FROM \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$YHUB_DB_NAME\" TO \"$YHUB_ROLE\"";
              psql -v ON_ERROR_STOP=1 -d "$YHUB_DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -d "$YHUB_DB_NAME" -c "ALTER SCHEMA public OWNER TO \"$YHUB_ROLE\"";
              # Tables/sequences/views created before the role existed (6.1.1
              # rollout: init-db ran as the tenant role) move to it. Indexes
              # follow their table. Per object, not REASSIGN OWNED: that would
              # also hand over the tenant role's OTHER databases.
              psql -v ON_ERROR_STOP=1 -d "$YHUB_DB_NAME" <<SQL
              DO \$\$
              DECLARE r record;
              BEGIN
                FOR r IN
                  SELECT c.relname, c.relkind FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relkind IN ('r','p','S','v','m')
                    AND pg_get_userbyid(c.relowner) <> '$YHUB_ROLE'
                    AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a','i')))
                LOOP
                  EXECUTE format('ALTER %s public.%I OWNER TO %I',
                    CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
                    r.relname, '$YHUB_ROLE');
                END LOOP;
                -- Functions and types too (none in yhub 6.1.1's schema; a
                -- future one must not stay superuser-owned: a SECURITY
                -- DEFINER function would run as the superuser, and init-db
                -- could not CREATE OR REPLACE it).
                FOR r IN
                  SELECT p.oid::regprocedure AS sig FROM pg_proc p
                  WHERE p.pronamespace = 'public'::regnamespace
                    AND pg_get_userbyid(p.proowner) <> '$YHUB_ROLE'
                LOOP
                  EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.sig, '$YHUB_ROLE');
                END LOOP;
                FOR r IN
                  SELECT t.oid::regtype AS typ FROM pg_type t
                  WHERE t.typnamespace = 'public'::regnamespace
                    -- enum/domain/range (a range's multirange follows it, and
                    -- refuses a direct ALTER), plus standalone composites,
                    -- whose typrelid points at a relkind 'c' pg_class row.
                    AND (
                      (t.typtype IN ('e','d','r') AND t.typrelid = 0)
                      OR (t.typtype = 'c' AND (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
                    )
                    AND pg_get_userbyid(t.typowner) <> '$YHUB_ROLE'
                LOOP
                  EXECUTE format('ALTER TYPE %s OWNER TO %I', r.typ, '$YHUB_ROLE');
                END LOOP;
              END
              \$\$;
              SQL

              # Pre-create common PostgreSQL extensions that may require C language functions
              # These need to be created as superuser (postgres) before migrations run
              # This prevents "permission denied for language c" errors during migrations
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS unaccent" || true;
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS fuzzystrmatch" || true;
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm" || true;

              # Ensure Keycloak role exists (shared across all tenants)
              # Password comes from KEYCLOAK_DB_PASSWORD env var (set by create_env from tenant secrets)
              KEYCLOAK_ROLE_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='keycloak'" || true)
              KC_PW=$(printf "%s" "${KEYCLOAK_DB_PASSWORD}" | sed "s/'/''/g")
              if [ "$KEYCLOAK_ROLE_EXISTS" != "1" ]; then
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE keycloak LOGIN PASSWORD '$KC_PW'";
              else
                # Update password in case it changed
                psql -v ON_ERROR_STOP=1 -c "ALTER ROLE keycloak WITH PASSWORD '$KC_PW'";
              fi

              # Ensure Keycloak database exists (shared across all tenants)
              KEYCLOAK_DB_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname='keycloak'" || true)
              if [ "$KEYCLOAK_DB_EXISTS" != "1" ]; then
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE keycloak OWNER keycloak";
              fi

              # Revoke default PUBLIC connect privilege on keycloak DB for cross-tenant isolation
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE keycloak TO keycloak";
              psql -v ON_ERROR_STOP=1 -d keycloak -c "REVOKE ALL ON SCHEMA public FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -d keycloak -c "GRANT ALL ON SCHEMA public TO keycloak";
              
              echo "=== Docs database initialization complete ==="
