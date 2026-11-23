# Matrix Authentication Service (MAS) - PostgreSQL Database Initialization Job
# Creates the MAS database and role on the shared PostgreSQL VM (via PgBouncer).
# Idempotent: safe to re-run on every deploy.
#
# Required environment variables:
#   NS_MATRIX   - Tenant matrix namespace (e.g., tn-example-matrix)
#   MAS_DB_NAME - Database name (e.g., mas_example)
#   MAS_DB_USER - Database role (e.g., mas_example)
#   PG_HOST     - PostgreSQL host (e.g., pgbouncer.infra-db.svc.cluster.local)

apiVersion: batch/v1
kind: Job
metadata:
  name: mas-db-init
  namespace: ${NS_MATRIX}
  labels:
    app.kubernetes.io/name: mas
    app.kubernetes.io/component: db-init
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mas
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
          image: postgres:18
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
                  name: postgres-credentials
                  key: postgres-password
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mas-config
                  key: db-password
            - name: DB_NAME
              value: "${MAS_DB_NAME}"
            - name: DB_USER
              value: "${MAS_DB_USER}"
          command:
            - /bin/bash
            - -lc
            - |
              set -euo pipefail
              echo "=== MAS Database Initialization ==="
              echo "Database name: $DB_NAME"
              echo "Database user: $DB_USER"

              # Escape single quotes in password for SQL literal
              ESC_PW=$(printf "%s" "$DB_PASSWORD" | sed "s/'/''/g")

              ROLE_EXISTS=$(psql -v ON_ERROR_STOP=1 -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")
              if [ "$ROLE_EXISTS" != "1" ]; then
                echo "Creating role $DB_USER..."
                psql -v ON_ERROR_STOP=1 -c "CREATE ROLE \"$DB_USER\" LOGIN"
              fi
              psql -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$DB_USER\" WITH PASSWORD '$ESC_PW'"

              DB_EXISTS=$(psql -v ON_ERROR_STOP=1 -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")
              if [ "$DB_EXISTS" != "1" ]; then
                echo "Creating database '$DB_NAME' with owner '$DB_USER'..."
                psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\" ENCODING 'UTF8' TEMPLATE template0"
              else
                echo "Database '$DB_NAME' already exists, ensuring ownership..."
                psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\""
              fi

              # Only this tenant's MAS role (and PgBouncer's auth_query) may connect
              psql -v ON_ERROR_STOP=1 -c "REVOKE CONNECT ON DATABASE \"$DB_NAME\" FROM PUBLIC"
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"$DB_USER\""
              psql -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$DB_NAME\" TO \"pgbouncer\""

              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC"
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO \"$DB_USER\""
              psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "ALTER SCHEMA public OWNER TO \"$DB_USER\""

              echo "=== MAS database initialization complete ==="
