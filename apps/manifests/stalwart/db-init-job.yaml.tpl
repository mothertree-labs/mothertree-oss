# Stalwart Mail Server - PostgreSQL Database Initialization Job
# Creates the stalwart database and user in the shared PostgreSQL instance
#
# Required environment variables:
#   NS_MAIL - Tenant mail namespace (e.g., tn-example-mail)
#   STALWART_DB_NAME - Database name (e.g., stalwart_example)
#   STALWART_DB_USER - Database user (e.g., stalwart_example)

apiVersion: batch/v1
kind: Job
metadata:
  name: stalwart-db-init
  namespace: ${NS_MAIL}
  labels:
    app.kubernetes.io/name: stalwart
    app.kubernetes.io/component: db-init
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: stalwart
        app.kubernetes.io/component: db-init
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999  # postgres user in Debian-based postgres image
        seccompProfile:
          type: RuntimeDefault
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
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
            - name: STALWART_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: stalwart-secrets
                  key: STALWART_DB_PASSWORD
            - name: DB_NAME
              value: "${STALWART_DB_NAME}"
            - name: DB_USER
              value: "${STALWART_DB_USER}"
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              echo "=== Stalwart Database Initialization ==="
              echo "Database name: $DB_NAME"
              echo "Database user: $DB_USER"
              
              # Escape single quotes in password for SQL literal
              ESC_PW=$(printf "%s" "$STALWART_PASSWORD" | sed "s/'/''/g")

              # Ensure stalwart role exists
              ROLE_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" || true)
              if [ "$ROLE_EXISTS" != "1" ]; then
                echo "Creating role $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN";
              fi
              # Set password for this tenant's stalwart user
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

              # Grants in stalwart database for tenant user
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$DB_USER\"";
              
              # Pre-create extensions that Stalwart may use
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm" || true;
              
              echo "=== Stalwart database initialization complete ==="
