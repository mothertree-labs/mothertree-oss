# Roundcube Database Initialization Job
# Creates the PostgreSQL database and user for Roundcube
#
# Required environment variables:
#   NS_WEBMAIL - Tenant webmail namespace (e.g., tn-example-webmail)
#   ROUNDCUBE_DB_NAME - Database name (e.g., roundcube_example)
#   ROUNDCUBE_DB_USER - Database user (e.g., roundcube_example)

apiVersion: batch/v1
kind: Job
metadata:
  name: roundcube-db-init
  namespace: ${NS_WEBMAIL}
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 70  # postgres user in Alpine
        seccompProfile:
          type: RuntimeDefault
      restartPolicy: Never
      containers:
      - name: db-init
        image: postgres:18-alpine
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        command:
        - /bin/sh
        - -c
        - |
          set -euo pipefail
          echo "=== Roundcube Database Initialization ==="
          echo "Database name: ${ROUNDCUBE_DB_NAME}"
          echo "Database user: ${ROUNDCUBE_DB_USER}"
          
          # Connect to PostgreSQL and create database/user
          export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"
          
          # Escape single quotes for the SQL literal below. The password is NOT in
          # deploy-roundcube.sh's envsubst list, so it is expanded here, inside the
          # container, straight into a string literal -- a password containing '
          # produced `ERROR: syntax error at or near "with"` and cascaded into four
          # more failures. stalwart, synapse, docs and nextcloud all escape first;
          # this was the one that did not (#664).
          ESC_PW=$(printf "%s" "$ROUNDCUBE_DB_PASSWORD" | sed "s/'/''/g")

          # Deliberately NOT a `DO $$ ... $$` block, which is what the other four
          # templates avoid too. Dollar-quoting consumes raw characters until the
          # matching tag and does not respect single quotes inside the body, so a
          # password containing `$$` terminates the block early and the remainder
          # parses as top-level SQL -- doubling `'` cannot prevent that. The flat
          # form has no such escape hatch. The password stays on stdin rather
          # than in `psql -c` argv, so it is never visible in /proc/<pid>/cmdline.
          echo "Creating role ${ROUNDCUBE_DB_USER}..."
          ROLE_EXISTS=$(psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname = '${ROUNDCUBE_DB_USER}'")
          if [ "$ROLE_EXISTS" = "1" ]; then
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres <<EOF
          ALTER ROLE "${ROUNDCUBE_DB_USER}" PASSWORD '$ESC_PW';
          EOF
          echo "Role ${ROUNDCUBE_DB_USER} already exists, password updated"
          else
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres <<EOF
          CREATE ROLE "${ROUNDCUBE_DB_USER}" LOGIN PASSWORD '$ESC_PW';
          EOF
          echo "Role ${ROUNDCUBE_DB_USER} created"
          fi
          
          echo "Creating database ${ROUNDCUBE_DB_NAME}..."
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres <<EOF
          SELECT 'CREATE DATABASE "${ROUNDCUBE_DB_NAME}" OWNER "${ROUNDCUBE_DB_USER}"'
          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${ROUNDCUBE_DB_NAME}')\gexec
          EOF
          
          echo "Granting permissions..."
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres <<EOF
          GRANT ALL PRIVILEGES ON DATABASE "${ROUNDCUBE_DB_NAME}" TO "${ROUNDCUBE_DB_USER}";
          EOF

          # Revoke default PUBLIC connect privilege so other tenant users cannot connect.
          # Also grant CONNECT to pgbouncer so it can run auth_query (looks up client
          # password hash from pg_shadow on the client's requested DB).
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d postgres <<EOF
          REVOKE CONNECT ON DATABASE "${ROUNDCUBE_DB_NAME}" FROM PUBLIC;
          GRANT CONNECT ON DATABASE "${ROUNDCUBE_DB_NAME}" TO "${ROUNDCUBE_DB_USER}";
          GRANT CONNECT ON DATABASE "${ROUNDCUBE_DB_NAME}" TO "pgbouncer";
          EOF

          # Grant schema permissions (needed for newer PostgreSQL versions)
          # Also revoke PUBLIC schema access for cross-tenant isolation
          psql -v ON_ERROR_STOP=1 -h ${PG_HOST} -U postgres -d "${ROUNDCUBE_DB_NAME}" <<EOF
          REVOKE ALL ON SCHEMA public FROM PUBLIC;
          GRANT ALL ON SCHEMA public TO "${ROUNDCUBE_DB_USER}";
          EOF
          
          echo "=== Database initialization complete ==="
        env:
        - name: POSTGRES_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: postgres-password
        - name: ROUNDCUBE_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBE_DB_PASSWORD
