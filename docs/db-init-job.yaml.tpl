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
  template:
    metadata:
      labels:
        app.kubernetes.io/name: docs
        app.kubernetes.io/part-of: mother-tree
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
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
                  name: docs-postgresql
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
