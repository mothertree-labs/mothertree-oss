apiVersion: batch/v1
kind: Job
metadata:
  name: nextcloud-db-init
  namespace: docs
  labels:
    app.kubernetes.io/name: nextcloud
    app.kubernetes.io/part-of: mother-tree
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nextcloud
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
              value: "${NEXTCLOUD_DB_NAME}"
            - name: DB_USER
              value: "${TENANT_DB_USER}"
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              echo "=== Nextcloud Database Initialization ==="
              echo "Database name: $DB_NAME"
              echo "Database user: $DB_USER"
              
              # Escape single quotes in password for SQL literal
              ESC_PW=$(printf "%s" "$DOCS_PASSWORD" | sed "s/'/''/g")

              # Ensure per-tenant role exists (e.g., docs_example)
              # This may already exist from docs-db-init, but we ensure it here too
              ROLE_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" || true)
              if [ "$ROLE_EXISTS" != "1" ]; then
                echo "Creating role $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN";
              fi
              # Ensure password is set (idempotent)
              psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH PASSWORD '$ESC_PW'";

              # Ensure nextcloud database exists (tenant-specific name)
              echo "Checking if $DB_NAME database exists..."
              DB_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" || true)
              if [ "$DB_EXISTS" != "1" ]; then
                echo "Creating $DB_NAME database with owner $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\""
                echo "Database '$DB_NAME' created successfully"
              else
                echo "Database '$DB_NAME' already exists, ensuring ownership..."
                psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\""
              fi

              # Revoke default PUBLIC connect privilege so other tenant users cannot connect
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$DB_NAME\" FROM PUBLIC"
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$DB_USER\""

              # Grant permissions to per-tenant user on nextcloud database
              echo "Granting permissions to $DB_USER..."
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_USER\""
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$DB_USER\""
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$DB_USER\""

              echo "=== Nextcloud database initialization complete ==="
