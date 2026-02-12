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
        image: postgres:15-alpine
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "=== Roundcube Database Initialization ==="
          echo "Database name: ${ROUNDCUBE_DB_NAME}"
          echo "Database user: ${ROUNDCUBE_DB_USER}"
          
          # Connect to PostgreSQL and create database/user
          export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"
          
          echo "Creating role ${ROUNDCUBE_DB_USER}..."
          psql -h ${PG_HOST} -U postgres -d postgres <<EOF
          DO \$\$
          BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${ROUNDCUBE_DB_USER}') THEN
              CREATE ROLE "${ROUNDCUBE_DB_USER}" LOGIN PASSWORD '$ROUNDCUBE_DB_PASSWORD';
              RAISE NOTICE 'Role ${ROUNDCUBE_DB_USER} created';
            ELSE
              ALTER ROLE "${ROUNDCUBE_DB_USER}" PASSWORD '$ROUNDCUBE_DB_PASSWORD';
              RAISE NOTICE 'Role ${ROUNDCUBE_DB_USER} already exists, password updated';
            END IF;
          END
          \$\$;
          EOF
          
          echo "Creating database ${ROUNDCUBE_DB_NAME}..."
          psql -h ${PG_HOST} -U postgres -d postgres <<EOF
          SELECT 'CREATE DATABASE "${ROUNDCUBE_DB_NAME}" OWNER "${ROUNDCUBE_DB_USER}"'
          WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${ROUNDCUBE_DB_NAME}')\gexec
          EOF
          
          echo "Granting permissions..."
          psql -h ${PG_HOST} -U postgres -d postgres <<EOF
          GRANT ALL PRIVILEGES ON DATABASE "${ROUNDCUBE_DB_NAME}" TO "${ROUNDCUBE_DB_USER}";
          EOF

          # Revoke default PUBLIC connect privilege so other tenant users cannot connect
          psql -h ${PG_HOST} -U postgres -d postgres <<EOF
          REVOKE CONNECT ON DATABASE "${ROUNDCUBE_DB_NAME}" FROM PUBLIC;
          GRANT CONNECT ON DATABASE "${ROUNDCUBE_DB_NAME}" TO "${ROUNDCUBE_DB_USER}";
          EOF

          # Grant schema permissions (needed for newer PostgreSQL versions)
          # Also revoke PUBLIC schema access for cross-tenant isolation
          psql -h ${PG_HOST} -U postgres -d "${ROUNDCUBE_DB_NAME}" <<EOF
          REVOKE ALL ON SCHEMA public FROM PUBLIC;
          GRANT ALL ON SCHEMA public TO "${ROUNDCUBE_DB_USER}";
          EOF
          
          echo "=== Database initialization complete ==="
        env:
        - name: POSTGRES_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: docs-postgresql
              key: postgres-password
        - name: ROUNDCUBE_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: roundcube-secrets
              key: ROUNDCUBE_DB_PASSWORD
