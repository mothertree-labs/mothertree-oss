# Synapse Matrix Server - PostgreSQL Database Initialization Job
# Creates the synapse database and user in the shared PostgreSQL instance
#
# CRITICAL: Synapse requires LC_COLLATE=C and LC_CTYPE=C on the database.
# Without C collation, Synapse will fail with collation errors.
#
# Required environment variables:
#   NS_MATRIX - Tenant matrix namespace (e.g., tn-example-matrix)
#   SYNAPSE_DB_NAME - Database name (e.g., synapse_example)
#   SYNAPSE_DB_USER - Database user (e.g., synapse_example)
#   PG_HOST - PostgreSQL host (e.g., docs-postgresql-primary.infra-db.svc.cluster.local)

apiVersion: batch/v1
kind: Job
metadata:
  name: synapse-db-init
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: matrix-synapse
    app.kubernetes.io/component: db-init
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: matrix-synapse
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
            - name: SYNAPSE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: synapse-db-secrets
                  key: SYNAPSE_DB_PASSWORD
            - name: DB_NAME
              value: "${SYNAPSE_DB_NAME}"
            - name: DB_USER
              value: "${SYNAPSE_DB_USER}"
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              echo "=== Synapse Database Initialization ==="
              echo "Database name: $DB_NAME"
              echo "Database user: $DB_USER"

              # Escape single quotes in password for SQL literal
              ESC_PW=$(printf "%s" "$SYNAPSE_PASSWORD" | sed "s/'/''/g")

              # Ensure synapse role exists
              ROLE_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" || true)
              if [ "$ROLE_EXISTS" != "1" ]; then
                echo "Creating role $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN";
              fi
              # Set password for this tenant's synapse user
              psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH PASSWORD '$ESC_PW'";

              # Ensure database exists with C collation (CRITICAL for Synapse)
              DB_EXISTS=$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" || true)
              if [ "$DB_EXISTS" != "1" ]; then
                echo "Creating database '$DB_NAME' with owner '$DB_USER' (LC_COLLATE=C, LC_CTYPE=C)..."
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\" ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0";
              else
                echo "Database '$DB_NAME' already exists, ensuring ownership..."
                psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\"";
                # Verify collation is C (warn if not)
                COLLATION=$(psql -Atqc "SELECT datcollate FROM pg_database WHERE datname='$DB_NAME'" || true)
                if [ "$COLLATION" != "C" ]; then
                  echo "WARNING: Database '$DB_NAME' has collation '$COLLATION' instead of 'C'"
                  echo "WARNING: Synapse requires C collation. You may need to recreate the database."
                fi
              fi

              # Revoke default PUBLIC connect privilege so other tenant users cannot connect
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$DB_NAME\" FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"";

              # Grants in synapse database for tenant user
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$DB_USER\"";
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$DB_USER\"";

              echo "=== Synapse database initialization complete ==="
